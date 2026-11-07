#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Completion of shared work. Individual waiter cancellation does not cancel the work
/// or affect other waiters. A receipt is in-memory and provides no durability guarantee.
public actor WorkReceipt {
  private var result: Result<Void, any Error>?
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

  /// Creates an unfinished receipt.
  public init() {}

  /// Waits for completion, or promptly throws when this waiter is cancelled.
  public func wait() async throws {
    try Task.checkCancellation()
    if let result { return try result.get() }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
        else { waiters[id] = continuation }
      }
    } onCancel: { Task { await self.cancel(id) } }
  }

  /// Completes all current and future waiters. Only the first completion has an effect.
  public func finish(_ result: Result<Void, any Error>) {
    guard self.result == nil else { return }
    self.result = result
    for waiter in waiters.values { waiter.resume(with: result) }
    waiters.removeAll()
  }

  private func cancel(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
}
