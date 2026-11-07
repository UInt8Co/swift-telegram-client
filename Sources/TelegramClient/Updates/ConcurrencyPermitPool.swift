#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// FIFO capacity admission without pacing or automatic retry. Permits cover only the
/// supplied operation; place retry sleeps outside it to release capacity between attempts.
public actor ConcurrencyPermitPool {
  private var available: Int
  private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []

  /// Creates a pool. Nonpositive capacity is clamped to one.
  public init(_ limit: Int) { available = max(1, limit) }

  /// Waits for capacity then runs once, releasing on success, failure or cancellation.
  /// Queued cancellation removes the waiter promptly. Running work must cooperate with
  /// cancellation. FIFO admission does not guarantee completion order.
  public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
        else if available > 0 { available -= 1; continuation.resume() }
        else { waiting.append((id, continuation)) }
      }
    } onCancel: { Task { await self.cancel(id) } }
    defer {
      if waiting.isEmpty { available += 1 }
      else { waiting.removeFirst().1.resume() }
    }
    try Task.checkCancellation()
    return try await operation()
  }

  private func cancel(_ id: UUID) {
    guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
    waiting.remove(at: index).1.resume(throwing: CancellationError())
  }
}
