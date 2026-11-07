/// Bounds concurrent requests and spaces their starts using a continuous clock.
/// Share one instance for the desired account/method budget. Capacity waiters
/// are admitted FIFO; actor scheduling does not guarantee operation start order
/// when multiple capacity holders are waiting for spacing.
public actor RequestLimiter {
  private let interval: Duration
  private let permits: ConcurrencyPermitPool
  private var nextStart = ContinuousClock.now

  /// Creates a limiter. The interval is between operation starts, not completions.
  /// Nonpositive concurrency limits are clamped to one.
  public init(interval: Duration, concurrencyLimit: Int = 1) {
    self.interval = interval; self.permits = ConcurrencyPermitPool(concurrencyLimit)
  }

  /// Acquires capacity, waits for start spacing, then runs once. Flood errors
  /// extend the next start deadline (including the directive clock margin) and
  /// propagate unchanged. Cancellation removes queued waiters promptly and
  /// releases capacity; a running operation must cooperate with cancellation.
  public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    try await permits.run { try await self.runPaced(operation) }
  }

  private func runPaced<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    while nextStart > .now { try await Task.sleep(until: nextStart, clock: .continuous) }
    try Task.checkCancellation()
    nextStart = .now.advanced(by: interval)
    do { return try await operation() }
    catch {
      if let wait = MTProtoDirective(error)?.wait { nextStart = max(nextStart, .now.advanced(by: wait)) }
      throw error
    }
  }
}
