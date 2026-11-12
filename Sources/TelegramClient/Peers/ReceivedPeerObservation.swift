import Synchronization
import TLCoding
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Where a connection hands every user and chat it receives, and the observer
/// they go to once one is attached.
///
/// Create one, pass it to `TelegramConnection.connect(…, receivedPeers:)`, and
/// attach an observer whenever the store it writes to can be opened — before
/// connecting, or after, once the login it is scoped by is known. Nothing
/// received in between is lost: it is held, in arrival order, and observed on
/// attachment.
///
/// - **Results** of RPCs made through ``PeerObservingTransport`` are observed
///   before the caller has them, once an observer is attached and everything held
///   before it has been observed; until then the caller has them at once and
///   they are held. Results of the RPCs a connection makes while connecting are
///   always held, so observing them can never fail a login. Throwing for a
///   result the caller is waiting for withholds it (``PeerObservationFailure``);
///   ``ReceivedPeers/Call/withholdsResultOnFailure`` says which those are.
/// - **Pushes** are observed one at a time, in arrival order, and each is handed
///   on only after its observation — so pushes received before attachment wait
///   for it. **A push is never lost to an observer that throws**: the failure is
///   reported to the failure handler, then the push is handed on all the same.
///   Some pushes cannot wait for the difference to bring them again
///   (a pre-checkout query must be answered within seconds).
/// - Failures that no caller is waiting for — a push's, a held result's — go to
///   the failure handler with the peers that were not observed, so a consumer can
///   keep them for later; the default handler logs a warning.
///
/// The server pushes regardless of how fast pushes are consumed, so the queue is
/// unbounded: a slow or unattached observer grows it instead of losing anything.
/// One observation can serve several connections — a ``TelegramClientPool``
/// shares its main connection's with the connections it opens.
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

  private enum Item: Sendable {
    /// A push, handed on after its peers, if any, were observed.
    case push(ReceivedPeers, handOn: @Sendable (TL.UpdatesType) -> Void)
    /// A result its caller already has.
    case held(ReceivedPeers)
    /// A result its caller waits for; the continuation answers the caller.
    case awaited(ReceivedPeers, CheckedContinuation<ReceivedPeersObserver?, any Error>)
    /// Someone waiting until everything queued before this was processed.
    case flush(CheckedContinuation<Void, Never>)

    var needsObserver: Bool {
      switch self {
      case .push(let peers, _): !peers.isEmpty
      case .held, .awaited: true
      case .flush: false
      }
    }
  }

  private struct State {
    var observer: ReceivedPeersObserver?
    /// The head stays queued while it is processed, so an empty queue means idle.
    var queue: [Item] = []
  }

  private final class Shared: Sendable {
    let state = Mutex(State())
  }

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
          await Self.process(item, observer: observer, report: report)
          shared.state.withLock { _ = $0.queue.removeFirst() }
        }
      }
    }
  }

  deinit { wake.finish() }

  /// Starts observing: everything held so far is observed, in arrival order, then
  /// every peer from now on. Returns once what was held has been observed — and
  /// the pushes among it handed on.
  ///
  /// Results that arrive while held peers are still being observed wait behind
  /// them, so nothing is observed out of order. Attach once.
  public func attach(_ observer: @escaping ReceivedPeersObserver) async {
    let attached = shared.state.withLock { state in
      guard state.observer == nil else { return false }
      state.observer = observer
      return true
    }
    precondition(attached, "a ReceivedPeerObservation is attached once")
    await flush()
  }

  /// Returns once everything received before the call has been observed and every
  /// push among it handed on. Waits for attachment if something needs observing.
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
  /// observer threw for a result its caller waits for.
  func observe(result peers: ReceivedPeers, callerWaits: Bool) async throws {
    enum Route { case held, inline(ReceivedPeersObserver), queued }
    var held = peers
    held.markHeld()
    let inline = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<ReceivedPeersObserver?, any Error>) in
      let route = shared.state.withLock { state -> Route in
        guard callerWaits, let observer = state.observer else {
          state.queue.append(.held(held))
          return .held
        }
        if state.queue.isEmpty { return .inline(observer) }
        state.queue.append(.awaited(peers, continuation))
        return .queued
      }
      switch route {
      case .held:
        wake.yield()
        continuation.resume(returning: nil)
      case .inline(let observer):
        continuation.resume(returning: observer)
      case .queued:
        wake.yield()
      }
    }
    if let inline { try await inline(peers) }
  }

  private static func process(
    _ item: Item, observer: ReceivedPeersObserver?, report: @Sendable (Failure) -> Void
  ) async {
    switch item {
    case .push(let peers, let handOn):
      if let observer, !peers.isEmpty {
        do { try await observer(peers) } catch { report(Failure(peers: peers, error: error)) }
      }
      if let updates = peers.pushed { handOn(updates) }
    case .held(let peers):
      guard let observer else { return }
      do { try await observer(peers) } catch { report(Failure(peers: peers, error: error)) }
    case .awaited(let peers, let continuation):
      guard let observer else { return continuation.resume(returning: nil) }
      do {
        try await observer(peers)
        continuation.resume(returning: nil)
      } catch {
        continuation.resume(throwing: error)
      }
    case .flush(let continuation):
      continuation.resume()
    }
  }
}

extension ReceivedPeers {
  fileprivate mutating func markHeld() {
    guard case .result(var call) = origin else { return }
    call.withholdsResultOnFailure = false
    origin = .result(call)
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
/// The request's constructor number says what its result decodes to; a wrapper
/// (`invokeWithoutUpdates`, `invokeWithLayer`, …) is stepped into to find the
/// method it carries. Every method of ``TelegramSchema`` whose result can hold a
/// peer is known (`Scripts/generate-received-peers.ts`); a method from another
/// schema generated on top of it is passed through unobserved.
///
/// A result is decoded once here and again by `TLClient`: the transport hands
/// over bytes and receives bytes, so the decoded value cannot be shared. A
/// result that does not decode here is passed on untouched, and `TLClient` fails
/// it with the same error.
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

  public func send(_ requestBody: Data) async throws -> Data {
    let context = ReceivedPeers.context
    let reply = try await base.send(requestBody)
    guard let reader = ReceivedPeerReplies.reader(forRequest: requestBody),
      let read = try? reader.read(reply), !read.peers.isEmpty
    else { return reply }
    let peers = ReceivedPeers(
      users: read.peers.users, chats: read.peers.chats,
      origin: .result(
        .init(
          method: reader.method, function: reader.function, result: read.result,
          context: context, withholdsResultOnFailure: callersWait)))
    do {
      try await observation.observe(result: peers, callerWaits: callersWait)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PeerObservationFailure(method: reader.method, underlying: error)
    }
    return reply
  }
}
