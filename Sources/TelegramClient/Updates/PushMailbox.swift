import Synchronization
import TelegramSchema

/// Lossless, arrival-ordered pushed updates with coalesced wakeups and poll requests.
/// Bounded drains limit work per pass, not retained backlog: this is not backpressure.
/// Producers may keep pushing after finish, but no further wakeups will be emitted.
public final class PushMailbox: Sendable {
  /// One received container with its monotonic arrival timestamp.
  public struct Entry: Sendable {
    /// Decoded pushed updates.
    public var updates: TL.UpdatesType
    /// Arrival time supplied by the producer.
    public var received: ContinuousClock.Instant
  }

  /// A drain of pushed containers and the poll flag consumed with that drain.
  public struct Batch: Sendable {
    /// Containers in arrival order.
    public var pushes: [TL.UpdatesType] = []
    /// Whether a poll asked for everything to be caught up.
    public var poll = false
    /// Creates a batch for an update consumer.
    public init(pushes: [TL.UpdatesType] = [], poll: Bool = false) {
      self.pushes = pushes; self.poll = poll
    }
  }

  /// Timestamped bounded drain, including any pending poll request.
  public struct Drain: Sendable {
    /// Containers in arrival order, at most the requested limit.
    public var entries: [Entry]
    /// Pending poll request consumed by this drain, even when pushes remain.
    public var poll: Bool
  }

  private struct State {
    var entries: [Entry?] = []
    var head = 0
    var poll = false
  }
  /// Coalesces wakeups; a partial drain re-signals remaining work.
  public let wakes: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let state = Mutex(State())
  private let observer: @Sendable (Int) -> Void

  /// Creates a mailbox. The optional depth observer runs outside the lock and may be
  /// called concurrently; observations can arrive out of order and must not block.
  public init(observer: @escaping @Sendable (Int) -> Void = { _ in }) {
    self.observer = observer
    (wakes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// Adds a decoded container without dropping earlier arrivals.
  public func push(_ updates: TL.UpdatesType, now: ContinuousClock.Instant = .now) {
    let depth = state.withLock {
      $0.entries.append(Entry(updates: updates, received: now))
      return $0.entries.count - $0.head
    }
    observer(depth)
    wake()
  }

  /// Requests catch-up on the next drain, whether or not pushes are pending.
  public func poll() {
    state.withLock { $0.poll = true }
    wake()
  }

  /// Signals work without setting the poll flag.
  public func wake() { continuation.yield() }

  /// Takes all currently waiting pushes and consumes the poll flag.
  public func take() -> Batch {
    let result = drain(limit: Int.max)
    return Batch(pushes: result.entries.map(\.updates), poll: result.poll)
  }

  /// Takes at most `limit` containers; nonpositive limits mean one. Remaining containers
  /// trigger another wakeup. Poll requests are consumed once, on the next drain.
  public func drain(limit: Int = 32) -> Drain {
    let (result, depth) = state.withLock { state in
      let count = min(state.entries.count - state.head, max(1, limit))
      let end = state.head + count
      let entries = state.entries[state.head..<end].compactMap { $0 }
      let result = Drain(entries: entries, poll: state.poll)
      state.poll = false
      for index in state.head..<end { state.entries[index] = nil }
      state.head = end
      if state.head == state.entries.count { state = State() }
      else if state.head >= 1024 && state.head >= state.entries.count / 2 {
        state.entries.removeFirst(state.head)
        state.head = 0
      }
      return (result, state.entries.count - state.head)
    }
    observer(depth)
    if depth > 0 { wake() }
    return result
  }

  /// Estimates retained decoded values outside the lock, without TL serialization.
  /// Shared payloads may be counted more than once. Maxima describe this snapshot.
  public func metrics(now: ContinuousClock.Instant = .now) -> WorkMetrics {
    let entries = state.withLock { $0.entries[$0.head...].compactMap { $0 } }
    let bytes = entries.reduce(0) { $0 + MemoryLayout<Entry>.stride + DecodedSizeEstimate.bytes($1.updates) }
    return .init(depth: entries.count, maxDepth: entries.count, estimatedBytes: bytes,
      maxEstimatedBytes: bytes, laneCount: entries.isEmpty ? 0 : 1,
      oldest: entries.reduce(.zero) { max($0, $1.received.duration(to: now)) })
  }

  /// Ends the wake stream; retained containers can still be drained.
  public func finish() { continuation.finish() }
}
