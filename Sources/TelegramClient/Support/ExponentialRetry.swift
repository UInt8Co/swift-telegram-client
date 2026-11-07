/// Configurable exponential retry for operations the caller knows are repeatable.
/// A timeout does not guarantee that a server-side mutation was not applied.
public enum ExponentialRetry {
  /// Default first delay between attempts.
  public static let firstWait: Duration = .seconds(1)
  /// Default maximum delay between attempts.
  public static let longestWait: Duration = .seconds(60)

  /// Doubles a nonnegative delay up to the configured ceiling without overflowing.
  public static func nextWait(after wait: Duration, longestWait: Duration = longestWait) -> Duration {
    precondition(wait >= .zero && longestWait >= .zero)
    return wait >= longestWait / 2 ? longestWait : min(wait * 2, longestWait)
  }

  /// Runs on the caller's actor, retrying only failures accepted by `shouldRetry`.
  /// Attempts are unlimited by default; `maximumAttempts` counts the initial call.
  /// The observer runs before each sleep. Cancellation errors and sleep failures
  /// propagate immediately, regardless of the predicate. The operation and sleep
  /// must cooperate with task cancellation. No delay follows the final attempt.
  public static func repeating<T>(
    isolation: isolated (any Actor)? = #isolation,
    firstWait: Duration = firstWait, longestWait: Duration = longestWait,
    maximumAttempts: Int? = nil,
    shouldRetry: (any Error) -> Bool,
    onRetry: (any Error, Duration) -> Void = { _, _ in },
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    _ operation: () async throws -> T
  ) async throws -> T {
    precondition(firstWait >= .zero && longestWait >= firstWait)
    precondition(maximumAttempts == nil || maximumAttempts! > 0)
    var wait = firstWait
    var remaining = maximumAttempts
    while true {
      do { return try await operation() }
      catch {
        guard !(error is CancellationError), shouldRetry(error) else { throw error }
        if let attempts = remaining {
          guard attempts > 1 else { throw error }
          remaining = attempts - 1
        }
        onRetry(error, wait)
        try await sleep(wait)
        wait = nextWait(after: wait, longestWait: longestWait)
      }
    }
  }
}
