import Synchronization
import TLCoding
import TelegramSchema

/// Where a connection hands every user and chat it receives, and the observer
/// they go to once one is attached.
///
/// Create one, pass it to `TelegramConnection.connect(…, receivedPeers:)`, and
/// attach an observer whenever the store it writes to can be opened — before
/// connecting, or after, once the login it is scoped by is known. Nothing
/// received in between is lost: it is held, in arrival order, and observed on
/// attachment.
///
/// What a consumer may rely on:
///
/// - **An RPC's peers are observed before its caller has the result.** Once the
///   held backlog is observed, a result is observed on its caller's task as soon
///   as it arrives — concurrently with other results and with pushes, never
///   queued behind them. Throwing for it withholds it (``PeerObservationFailure``).
/// - **Pushes are observed one at a time, in arrival order**, and each is handed
///   on only after its observation. **A push is never lost to an observer that
///   throws**: the failure is reported to the failure handler, then the push is
///   handed on all the same — some pushes (a pre-checkout query) cannot wait for
///   the difference to bring them again.
/// - **Everything received before ``attach(_:)`` is observed in arrival order
///   before anything received after it**: until then results reach their callers
///   at once and their peers are held with the pushes, and a result arriving
///   while that backlog is observed waits for the backlog — not for later pushes.
/// - **A push and a concurrent RPC result are not ordered** relative to each
///   other, as they never were: each is observed before it is handed on, and
///   neither waits for the other.
/// - **An RPC made from inside the observer** — directly, from a child task it
///   awaits, or nested several observations deep — is observed at once and
///   returned, ahead of anything queued, rather than waiting for the observation
///   that made it. (A `Task.detached` is not inside the observer.)
/// - Results of the RPCs a connection makes while connecting are never waited
///   for, so observing them can never fail a login; they are held, or observed
///   in the background behind earlier pushes.
/// - Failures that no caller is waiting for — a push's, a held result's — go to
///   the failure handler with the peers that were not observed, so a consumer
///   can keep them for later; the default handler logs a warning.
///   ``ReceivedPeers/Call/withholdsResultOnFailure`` says which results those are.
///
/// The server pushes regardless of how fast pushes are consumed, so the push
/// queue is unbounded: a slow or unattached observer grows it instead of losing
/// anything. One observation can serve several connections — a
/// ``TelegramClientPool`` shares its main connection's with the connections it
/// opens.
///
/// A test drives exactly the production path: results through a
/// ``PeerObservingTransport`` over a fake transport, pushes through
/// ``push(_:handingOnTo:)``, and ``flush()`` to wait for them.
public final class ReceivedPeerObservation: Sendable {
  /// Peers whose observation failed with no caller to fail instead.
  public struct Failure: Sendable {
    /// The peers that were not observed.
    public var peers: ReceivedPeers
    /// What the observer threw.
    public var error: any Error

    public init(peers: ReceivedPeers, error: any Error) {
      self.peers = peers
      self.error = error
    }
  }

  /// What the observation's own task works through, in order.
  private enum Item: Sendable {
    /// A push, handed on after its peers, if any, were observed.
    case push(ReceivedPeers, handOn: @Sendable (TL.UpdatesType) -> Void)
    /// A result its caller already has.
    case held(ReceivedPeers)
    /// Someone waiting until everything queued before this was processed.
    case flush(CheckedContinuation<Void, Never>)

    var needsObserver: Bool {
      switch self {
      case .push(let peers, _): !peers.isEmpty
      case .held: true
      case .flush: false
      }
    }
  }

  private struct State {
    var observer: ReceivedPeersObserver?
    /// The head stays queued while it is processed.
    var queue: [Item] = []
    /// How many items at the head of `queue` were received before attachment
    /// and are not yet observed. Results wait for this, never for the rest.
    var backlog = 0
    /// Callers whose results wait for the backlog, by waiter number.
    var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
    var nextWaiter = 0
    /// `attach` calls waiting for the backlog.
    var attaching: [CheckedContinuation<Void, Never>] = []
  }

  private final class Shared: Sendable {
    let state = Mutex(State())
  }

  /// The observations whose observer the current task is running inside.
  @TaskLocal private static var observing: Set<ObjectIdentifier> = []

  private let shared = Shared()
  private let wake: AsyncStream<Void>.Continuation

  /// - Parameters:
  ///   - log: Where the default failure handler writes.
  ///   - onFailure: Handed each failure no caller can be failed with instead.
  ///     Runs on the observation's own task, before the push concerned is
  ///     handed on; it must not block for long.
  public init(
    log: TelegramLog = .silent, onFailure: (@Sendable (Failure) -> Void)? = nil
  ) {
    let report =
      onFailure ?? { failure in
        let what = failure.peers.pushed == nil ? "a held result" : "a pushed update container"
        log.warning(
          "recording the peers of \(what) failed (\(failure.peers.users.count) user(s), "
            + "\(failure.peers.chats.count) chat(s)): \(failure.error)")
      }
    let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    self.wake = wake
    let shared = self.shared
    Task {
      for await _ in wakes {
        while let (item, observer) = shared.state.withLock({ state -> (Item, ReceivedPeersObserver?)? in
          guard let head = state.queue.first, state.observer != nil || !head.needsObserver
          else { return nil }
          return (head, state.observer)
        }) {
          await Self.process(item, observer: observer, in: shared, report: report)
          let drained = shared.state.withLock { state -> Drained? in
            state.queue.removeFirst()
            guard state.backlog > 0 else { return nil }
            state.backlog -= 1
            guard state.backlog == 0 else { return nil }
            defer { state.waiting = [:]; state.attaching = [] }
            return Drained(waiting: Array(state.waiting.values), attaching: state.attaching)
          }
          drained?.resume()
        }
      }
    }
  }

  deinit { wake.finish() }

  private struct Drained {
    var waiting: [CheckedContinuation<Void, any Error>]
    var attaching: [CheckedContinuation<Void, Never>]

    func resume() {
      for continuation in waiting { continuation.resume() }
      for continuation in attaching { continuation.resume() }
    }
  }

  /// Starts observing: everything held so far is observed, in arrival order, then
  /// every peer from now on. Returns once what was held has been observed — and
  /// the pushes among it handed on. Attach once.
  public func attach(_ observer: @escaping ReceivedPeersObserver) async {
    await withCheckedContinuation { continuation in
      let drained = shared.state.withLock { state -> Bool in
        precondition(state.observer == nil, "a ReceivedPeerObservation is attached once")
        state.observer = observer
        state.backlog = state.queue.count
        if state.backlog == 0 { return true }
        state.attaching.append(continuation)
        return false
      }
      if drained { continuation.resume() } else { wake.yield() }
    }
  }

  /// Returns once every push and held result received before the call has been
  /// observed and every push among them handed on. Waits for attachment if
  /// something needs observing. Results observed on their callers' tasks are not
  /// queued, so this does not wait for them.
  public func flush() async {
    await withCheckedContinuation { continuation in
      shared.state.withLock { $0.queue.append(.flush(continuation)) }
      wake.yield()
    }
  }

  /// Hands a pushed container to `handOn` after observing its peers, in the order
  /// pushes arrive. This is what a connection does with every push it receives.
  public func push(
    _ updates: TL.UpdatesType, handingOnTo handOn: @escaping @Sendable (TL.UpdatesType) -> Void
  ) {
    let peers = ReceivedPeers(pushed: updates)
    shared.state.withLock { $0.queue.append(.push(peers, handOn: handOn)) }
    wake.yield()
  }

  /// Observes a result before its caller has it, or holds it. Throws what the
  /// observer threw for a result its caller waits for, or `CancellationError` if
  /// the caller is cancelled while its result waits for the backlog — the peers
  /// are then held rather than lost.
  func observe(result peers: ReceivedPeers, callerWaits: Bool) async throws {
    let id = ObjectIdentifier(shared)
    // Made from inside the observer: observed at once, or it would wait for
    // the very observation that is waiting for it.
    if callerWaits, Self.observing.contains(id),
      let observer = shared.state.withLock({ $0.observer })
    {
      return try await Self.run(observer, peers, in: shared)
    }
    enum Route { case held, inline(ReceivedPeersObserver), wait }
    let route = shared.state.withLock { state -> Route in
      guard callerWaits, let observer = state.observer else {
        state.queue.append(.held(Self.held(peers)))
        return .held
      }
      return state.backlog == 0 ? .inline(observer) : .wait
    }
    switch route {
    case .held:
      wake.yield()
    case .inline(let observer):
      try await Self.run(observer, peers, in: shared)
    case .wait:
      do {
        try await waitForBacklog()
      } catch {
        shared.state.withLock { $0.queue.append(.held(Self.held(peers))) }
        wake.yield()
        throw error
      }
      guard let observer = shared.state.withLock({ $0.observer }) else { return }
      try await Self.run(observer, peers, in: shared)
    }
  }

  private func waitForBacklog() async throws {
    let waiter = shared.state.withLock { state in
      state.nextWaiter += 1
      return state.nextWaiter
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        enum Now { case wait, go, cancelled }
        let now = shared.state.withLock { state -> Now in
          if state.backlog == 0 { return .go }
          // Registered after a cancellation the handler could not find.
          if Task.isCancelled { return .cancelled }
          state.waiting[waiter] = continuation
          return .wait
        }
        switch now {
        case .wait: break
        case .go: continuation.resume()
        case .cancelled: continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      shared.state.withLock { $0.waiting.removeValue(forKey: waiter) }?
        .resume(throwing: CancellationError())
    }
  }

  /// Runs the observer with the current task marked as inside it.
  private static func run(
    _ observer: ReceivedPeersObserver, _ peers: ReceivedPeers, in shared: Shared
  ) async throws {
    try await $observing.withValue(observing.union([ObjectIdentifier(shared)])) {
      try await observer(peers)
    }
  }

  private static func held(_ peers: ReceivedPeers) -> ReceivedPeers {
    guard case .result(var call) = peers.origin else { return peers }
    call.withholdsResultOnFailure = false
    var held = peers
    held.origin = .result(call)
    return held
  }

  private static func process(
    _ item: Item, observer: ReceivedPeersObserver?, in shared: Shared,
    report: @Sendable (Failure) -> Void
  ) async {
    switch item {
    case .push(let peers, let handOn):
      if let observer, !peers.isEmpty {
        do { try await run(observer, peers, in: shared) } catch {
          report(Failure(peers: peers, error: error))
        }
      }
      if let updates = peers.pushed { handOn(updates) }
    case .held(let peers):
      guard let observer else { return }
      do { try await run(observer, peers, in: shared) } catch {
        report(Failure(peers: peers, error: error))
      }
    case .flush(let continuation):
      continuation.resume()
    }
  }
}

/// A transport that hands every user and chat in an RPC result to a
/// ``ReceivedPeerObservation``, returning the result once they were observed.
///
/// ``TelegramConnection`` installs this under its ``TelegramConnection/api``
/// when it is given an observation, so a caller that only uses a connection never
/// builds one. It is public for a client built over another transport — a test
/// double, or a decorator of a connection's transport — that must observe the
/// same way.
///
/// The result is the value the transport below decoded, read where it is and
/// handed on as it is: nothing is decoded a second time. It is observed when its
/// type can hold a peer — every such type of ``TelegramSchema`` is known
/// (`Scripts/generate-received-peers.ts`) — whichever method returned it; a
/// result of another type is passed through unobserved. The call is named after
/// the function a wrapper (`invokeWithoutUpdates`, `invokeWithLayer`, …)
/// carries, not the wrapper.
///
/// The observer runs on the caller's task, so concurrent calls observe
/// concurrently, and a slow observer delays exactly the calls whose results it is
/// observing. If it throws, the call fails with ``PeerObservationFailure`` — or
/// with the `CancellationError` it threw — instead of returning a result whose
/// peers were not recorded.
public struct PeerObservingTransport: TLClientTransport {
  public let base: any TLClientTransport
  public let observation: ReceivedPeerObservation
  /// Whether callers wait for observation. A connection's own RPCs while it
  /// connects do not, so observing them cannot fail the login.
  let callersWait: Bool

  public init(base: any TLClientTransport, observation: ReceivedPeerObservation) {
    self.init(base: base, observation: observation, callersWait: true)
  }

  init(base: any TLClientTransport, observation: ReceivedPeerObservation, callersWait: Bool) {
    self.base = base
    self.observation = observation
    self.callersWait = callersWait
  }

  public func invoke<Function: TLFunction>(_ function: Function) async throws -> Function.ReturnType {
    let context = ReceivedPeers.context
    let result = try await base.invoke(function)
    guard let carrier = result as? any ReceivedPeerCarrying else { return result }
    var list = ReceivedPeerList()
    carrier.collectReceivedPeers(into: &list)
    guard !list.isEmpty else { return result }
    let invoked = type(of: function.tlInnermostFunction)
    let peers = ReceivedPeers(
      users: list.users, chats: list.chats,
      origin: .result(
        .init(
          method: invoked.tlMethodName, function: invoked, result: result,
          context: context, withholdsResultOnFailure: callersWait)))
    do {
      try await observation.observe(result: peers, callerWaits: callersWait)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PeerObservationFailure(method: invoked.tlMethodName, underlying: error)
    }
    return result
  }
}
