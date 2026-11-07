/// Desired command menu state, independent of application language policy.
public enum BotCommandMenuState<Value: Equatable & Sendable>: Equatable, Sendable {
  /// Remove the specific scope so Telegram inherits the default command list.
  case inheritDefault
  /// Publish a caller-defined override (for example, a language or version).
  case override(Value)
}

/// Serializes menu writes per neutral key and avoids redundant process-local writes.
public actor BotCommandMenus<Key: Hashable & Sendable, Value: Equatable & Sendable> {
  private let cacheLimit: Int

  /// Creates a process-local cache. Exceeding the nonnegative limit evicts idle keys.
  public init(cacheLimit: Int = 4_096) {
    precondition(cacheLimit >= 0)
    self.cacheLimit = cacheLimit
  }

  private enum State: Equatable { case uncertain, applied(BotCommandMenuState<Value>) }
  private var applied: [Key: State] = [:]
  private var desired: [Key: BotCommandMenuState<Value>] = [:]
  private var running: Set<Key> = []

  /// Coalesces writes per key, publishing the latest requested state after an in-flight write.
  /// An overlapping caller returns immediately; the active caller owns publication and errors.
  /// Its publisher is used for all coalesced states. Different keys may publish concurrently.
  /// A failed or cancelled publisher leaves uncertain state so later calls retry. Cancellation
  /// is delegated to the publisher. `mayHaveOverride` requests a reset after cache loss;
  /// otherwise an uncached default state requires no write. This cache is not durable.
  public func update(user: Key, state: BotCommandMenuState<Value>, mayHaveOverride: Bool = false,
        publish: @Sendable (BotCommandMenuState<Value>) async throws -> Void) async throws {
    if applied[user] == nil, !mayHaveOverride, !running.contains(user), state == .inheritDefault {
      applied[user] = .applied(.inheritDefault)
    }
    desired[user] = state
    guard running.insert(user).inserted else { return }
    defer {
      running.remove(user)
      desired[user] = nil
      if applied.count > cacheLimit {
        applied = applied.filter { running.contains($0.key) }
      }
    }
    while let current = desired[user], applied[user] != .applied(current) {
      // A failed write may have reached Telegram; the next reset must not be suppressed.
      applied[user] = .uncertain
      try await publish(current)
      applied[user] = .applied(current)
    }
  }
}
