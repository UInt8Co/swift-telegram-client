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

  private init() {}

  /// Producer authority for an independently completed receipt. Share only `receipt`
  /// with consumers; retaining this token permits the producer to finish the work.
  public struct Completion: Sendable {
    /// The wait-only handle. Cancelling a waiter never completes or cancels shared work.
    public let receipt: WorkReceipt

    /// Creates an unfinished receipt and its completion authority.
    public init() { receipt = WorkReceipt() }

    /// Completes current and future waiters. Only the first completion takes effect.
    /// This does not cancel the producer operation; the producer owns its lifecycle.
    public func finish(_ result: Result<Void, any Error>) async {
      await receipt.finish(result)
    }
  }

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
  private func finish(_ result: Result<Void, any Error>) {
    guard self.result == nil else { return }
    self.result = result
    for waiter in waiters.values { waiter.resume(with: result) }
    waiters.removeAll()
  }

  private func cancel(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
}
