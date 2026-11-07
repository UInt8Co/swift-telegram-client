/// The owner renders content and persists each stream. Keep durable retry state
/// in the owner: settlement is attempted once, including when transport throws.
public protocol DraftStreamTransport<Key>: Sendable {
  /// An application-defined identity grouping independent draft streams.
  associatedtype Key: Hashable & Sendable
  /// Shows the current content of the stream identified by `draftID`.
  func showDraft(for key: Key, draftID: Int64) async throws
  /// Persists that stream as a real message, once per stream.
  func settle(_ key: Key, draftID: Int64, reason: DraftSettleReason) async throws
}

/// Identifies the operation whose thrown error is reported to the owner.
public enum DraftStreamOperation: Sendable, Equatable {
  /// A draft preview call.
  case showDraft
  /// A persistence attempt for the supplied reason.
  case settle(DraftSettleReason)
}

/// Coordinates growing replies on an injected clock. Calls for one key never
/// overlap; independent keys share a bounded number of transport slots.
///
/// Content belongs to the transport. On settlement it must freeze/remove that
/// generation before awaiting I/O, so new entries belong to the next draft ID.
/// Failures are delivered to `onError`; a draft failure cannot prevent settlement.
/// The concurrency bound limits calls, not queued generations or retained content.
/// No state survives a restart, and settlement is one attempt rather than guaranteed delivery.
public actor DraftStreamer<Key: Hashable & Sendable> {
  private struct Entry {
    let id: Int64
    var stream: DraftStream
  }

  private let transport: any DraftStreamTransport<Key>
  private let policy: DraftStreamPolicy
  private let maximumConcurrentCalls: Int
  private let now: @Sendable () -> Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let onError: @Sendable (Key, Int64, DraftStreamOperation, any Error) -> Void
  private let wakeups: AsyncStream<Void>
  private let wake: AsyncStream<Void>.Continuation
  private var entries: [Key: [Entry]] = [:]
  private var keysByID: [Int64: Key] = [:]
  private var order: [Key] = []
  private var inFlight: Set<Key> = []
  private var lastID: Int64?
  private var hasRun = false
  private var shuttingDown = false
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  /// Uses a continuous clock. `onError` receives draft and settlement errors;
  /// it should log or enqueue durable retries without blocking the scheduler.
  public init(
    transport: any DraftStreamTransport<Key>, policy: DraftStreamPolicy = .init(),
    maximumConcurrentCalls: Int = 4,
    onError: @escaping @Sendable (Key, Int64, DraftStreamOperation, any Error) -> Void
  ) {
    self.init(
      transport: transport, policy: policy, clock: ContinuousClock(),
      maximumConcurrentCalls: maximumConcurrentCalls, onError: onError)
  }

  /// Injects a clock for deterministic scheduling and tests.
  public init<C: Clock>(
    transport: any DraftStreamTransport<Key>, policy: DraftStreamPolicy = .init(),
    clock: C, maximumConcurrentCalls: Int = 4,
    onError: @escaping @Sendable (Key, Int64, DraftStreamOperation, any Error) -> Void
  )
  where C.Duration == Duration {
    precondition(maximumConcurrentCalls > 0)
    _ = DraftStream(policy: policy)
    self.transport = transport
    self.policy = policy
    self.maximumConcurrentCalls = maximumConcurrentCalls
    self.onError = onError
    let origin = clock.now
    now = { origin.duration(to: clock.now) }
    sleep = { try await clock.sleep(until: origin.advanced(by: $0), tolerance: nil) }
    (wakeups, wake) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// Records changed content, opening a fresh non-zero draft ID if necessary.
  /// Changes after `settleAll()` begins are ignored because intake is closed.
  /// Returns the generation ID so owners can attach entries atomically even
  /// when a deadline closes the previous generation before transport runs.
  @discardableResult
  public func changed(_ key: Key) -> Int64? {
    guard !shuttingDown else { return nil }
    if entries[key]?.last?.stream.isClosing != false {
      var id = Int64.random(in: 1...Int64.max)
      while keysByID[id] != nil || id == lastID { id = Int64.random(in: 1...Int64.max) }
      lastID = id
      if entries[key] == nil { order.append(key) }
      entries[key, default: []].append(.init(id: id, stream: .init(policy: policy)))
      keysByID[id] = key
    }
    let index = entries[key]!.count - 1
    entries[key]![index].stream.changed(at: now())
    wake.yield(())
    return entries[key]![index].id
  }

  /// Settles the matching generation. Unknown or already completed IDs do nothing.
  public func stop(draftID: Int64) {
    guard let key = keysByID[draftID],
      let index = entries[key]?.firstIndex(where: { $0.id == draftID })
    else { return }
    entries[key]![index].stream.stopped(at: now())
    wake.yield(())
  }

  /// Closes the newest generation for a key because its content is full.
  public func full(_ key: Key) {
    guard let count = entries[key]?.count, count > 0 else { return }
    entries[key]![count - 1].stream.full(at: now())
    wake.yield(())
  }

  /// Closes intake and waits for all settlement attempts, using `.stopped`
  /// for streams without an existing reason. Works even without `run()`.
  /// In-flight drafts finish first; persistence errors still reach `onError`.
  public func settleAll() async {
    shuttingDown = true
    for key in order {
      for index in entries[key]!.indices { entries[key]![index].stream.stopped(at: now()) }
    }
    drive()
    wake.yield(())
    guard !entries.isEmpty else { return }
    await withCheckedContinuation { drainWaiters.append($0) }
  }

  /// Drives deadlines until cancelled or drained by `settleAll()`. Call once.
  /// Cancellation stops the deadline driver; in-flight calls finish normally.
  /// Call `settleAll()` separately to drain pending content during shutdown.
  public func run() async {
    guard !hasRun else { return }
    hasRun = true
    var timer: Task<Void, Never>?
    defer { timer?.cancel() }
    wake.yield(())
    for await _ in wakeups {
      timer?.cancel()
      guard !Task.isCancelled else { break }
      drive()
      if shuttingDown && entries.isEmpty { break }
      if let deadline = nextDeadline() {
        let sleep = self.sleep
        let wake = self.wake
        timer = Task {
          do {
            try await sleep(deadline)
            if !Task.isCancelled { wake.yield(()) }
          } catch {}
        }
      }
    }
  }

  private func drive() {
    for key in order {
      guard inFlight.count < maximumConcurrentCalls else { break }
      guard !inFlight.contains(key), var entry = entries[key]?.first else { continue }
      let operation: DraftStreamOperation
      switch entry.stream.next(at: now()) {
      case .showDraft: operation = .showDraft
      case .settle(let reason): operation = .settle(reason)
      case .wait, .idle: continue
      }
      entries[key]![0] = entry
      inFlight.insert(key)
      // Rotate after dispatch so a busy key cannot starve the others.
      order.removeAll { $0 == key }
      order.append(key)
      let id = entry.id
      Task {
        do {
          switch operation {
          case .showDraft: try await transport.showDraft(for: key, draftID: id)
          case .settle(let reason): try await transport.settle(key, draftID: id, reason: reason)
          }
        } catch { onError(key, id, operation, error) }
        completed(key, id: id, operation: operation)
      }
    }
  }

  private func completed(_ key: Key, id: Int64, operation: DraftStreamOperation) {
    inFlight.remove(key)
    if case .settle = operation {
      entries[key]?.removeFirst()
      keysByID.removeValue(forKey: id)
      if entries[key]?.isEmpty == true {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
      }
    }
    if shuttingDown {
      drive()
      if entries.isEmpty {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      }
    }
    wake.yield(())
  }

  private func nextDeadline() -> Duration? {
    guard inFlight.count < maximumConcurrentCalls else { return nil }
    return order.compactMap { key -> Duration? in
      guard !inFlight.contains(key), var stream = entries[key]?.first?.stream else { return nil }
      switch stream.next(at: now()) {
      case .wait(let deadline): return deadline
      case .showDraft, .settle: return now()
      case .idle: return nil
      }
    }.min()
  }
}
