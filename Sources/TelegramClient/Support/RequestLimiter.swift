#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Bounds concurrent requests and spaces their starts using a continuous clock.
/// Share one instance for the desired account/method budget. Capacity waiters
/// are admitted FIFO; actor scheduling does not guarantee operation start order
/// when multiple capacity holders are waiting for spacing.
public actor RequestLimiter {
  private let interval: Duration
  private let concurrencyLimit: Int
  private var inFlight = 0
  private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
  private var nextStart = ContinuousClock.now
  /// Creates a limiter. The interval is between operation starts, not completions.
  /// Nonpositive concurrency limits are clamped to one.
  public init(interval: Duration, concurrencyLimit: Int = 1) {
    self.interval = interval; self.concurrencyLimit = max(1, concurrencyLimit)
  }

  /// Acquires capacity, waits for start spacing, then runs once. Flood errors
  /// extend the next start deadline (including the directive clock margin) and
  /// propagate unchanged. Cancellation removes queued waiters promptly and
  /// releases capacity; a running operation must cooperate with cancellation.
  public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
        else if inFlight >= concurrencyLimit { waiters.append((id, continuation)) }
        else { inFlight += 1; continuation.resume() }
      }
    } onCancel: { Task { await self.cancel(id) } }
    defer {
      if waiters.isEmpty { inFlight -= 1 }
      else { waiters.removeFirst().1.resume() }
    }
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
  private func cancel(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
    waiters.remove(at: index).1.resume(throwing: CancellationError())
  }

}

