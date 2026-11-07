/// Compare the committed state before encoding it. The timer flushes the latest
/// snapshot, and shutdown waits for any write already in flight before flushing.
public actor CheckpointWriter<Value: Equatable & Sendable> {
  private var saved: Value?
  private var latest: Value?
  private var writing: Task<Void, any Error>?
  private var revision: UInt64 = 0
  private let write: @Sendable (Value) async throws -> Void
  /// Number of successful writes by this instance.
  public private(set) var writes = 0

  /// Creates a writer whose saved value reflects existing storage. Writes are serialized.
  public init(saved: Value?, write: @escaping @Sendable (Value) async throws -> Void) {
    self.saved = saved
    latest = saved
    self.write = write
  }

  /// Publishes a snapshot only when its revision exceeds all previously accepted revisions.
  public func update(_ value: Value, revision: UInt64) {
    guard revision > self.revision else { return }
    self.revision = revision
    latest = value
  }

  /// Waits for an in-flight write, then writes the latest changed snapshot. A concurrent
  /// update during this call's own write needs another flush. Failure preserves the dirty
  /// snapshot for retry. Cancelling a flush does not cancel an already started write.
  public func flush() async throws {
    if let writing {
      try await writing.value
      return try await flush()
    }
    guard let value = latest, value != saved else { return }
    let task = Task {
      do {
        try await write(value)
        saved = value
        writes += 1
        writing = nil
      } catch {
        writing = nil
        throw error
      }
    }
    writing = task
    try await task.value
  }
}
