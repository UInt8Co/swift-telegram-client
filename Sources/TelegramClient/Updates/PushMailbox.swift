import Synchronization
import TelegramSchema

/// Pushed updates and poll requests wait here until an update loop takes them
/// all at once, so a burst of pushes costs one update pass, not one each.
///
/// Feed it from the connection's push callback and `poll()` from a timer, then
/// `take()` a batch whenever `wakes` yields.
public final class PushMailbox: Sendable {
  public struct Batch: Sendable {
    public var pushes: [TL.UpdatesType] = []
    /// Whether a poll asked for everything to be caught up.
    public var poll = false
    public init(pushes: [TL.UpdatesType] = [], poll: Bool = false) {
      self.pushes = pushes
      self.poll = poll
    }
  }
  /// Yields once whatever number of pushes and polls arrived since the last take.
  public let wakes: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let state = Mutex(Batch())

  public init() {
    (wakes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// Call from the connection's `onPushedUpdates` callback.
  public func push(_ updates: TL.UpdatesType) {
    state.withLock { $0.pushes.append(updates) }
    continuation.yield()
  }

  /// Asks the next pass to catch up, whether or not anything was pushed.
  public func poll() {
    state.withLock { $0.poll = true }
    continuation.yield()
  }

  /// Everything waiting, in arrival order, leaving the mailbox empty.
  public func take() -> Batch {
    state.withLock { batch in
      defer { batch = Batch() }
      return batch
    }
  }

  /// Ends `wakes`, so the update loop reading it returns.
  public func finish() { continuation.finish() }
}
