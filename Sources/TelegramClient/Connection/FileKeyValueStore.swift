#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif


/// Optional executor for blocking filesystem operations. Implementations must execute each
/// submitted closure exactly once and return its result, or throw without executing it.
public protocol FileIOExecutor: Sendable {
  /// Executes one complete filesystem operation. Cancellation must not return before a
  /// started operation completes, so the store can preserve write ordering.
  func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T
}

private struct InlineFileIOExecutor: FileIOExecutor {
  func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try operation()
  }
}

/// Opaque key-to-bytes storage with serialized, atomic replacement and owner-only files.
/// Filenames are lowercase hexadecimal UTF-8 key bytes plus `.json`; contents are opaque.
/// One instance must own a directory within a process; concurrent processes need separate
/// directories. Identical writes made by this instance are skipped. File I/O is synchronous
/// by default, like FileTelegramSessionStore; inject an executor for thread-pool offloading.
public actor FileKeyValueStore {
  private let directory: URL
  private let executor: any FileIOExecutor
  private var lastWrite: Task<Void, any Error>?
  private var saved: [String: Data] = [:]

  /// Creates the directory and restricts it to 0700. Initialization performs synchronous I/O.
  public init(directory: URL, executor: (any FileIOExecutor)? = nil) throws {
    self.executor = executor ?? InlineFileIOExecutor()
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  /// Reads after the preceding write, ignoring its failure. Missing files return nil;
  /// other read failures propagate. Later concurrent writes may overlap this read.
  public func read(key: String) async throws -> Data? {
    _ = try? await lastWrite?.value
    let url = url(for: key)
    return try await executor.run {
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try Data(contentsOf: url)
    }
  }

  /// Samples file existence without waiting for pending writes. It is a diagnostic
  /// snapshot, not a guarantee that the last write completed or that bytes are readable.
  public func exists(key: String) async throws -> Bool {
    let url = url(for: key)
    return try await executor.run {
      FileManager.default.fileExists(atPath: url.path)
    }
  }

  /// Serializes after prior writes (including failed ones), atomically replaces the file,
  /// then restricts permissions to 0600. Failed writes are not cached and can be retried.
  /// Cancelling a caller does not cancel the ordered write task already created.
  public func write(_ data: Data, key: String) async throws {
    let url = url(for: key)
    let previous = lastWrite
    let write = Task {
      _ = try? await previous?.value
      guard saved[key] != data else { return }
      try await executor.run {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
      saved[key] = data
    }
    lastWrite = write
    try await write.value
  }

  private func url(for key: String) -> URL {
    let safeKey = key.utf8.map { String($0 >> 4, radix: 16) + String($0 & 15, radix: 16) }.joined()
    return directory.appendingPathComponent(safeKey + ".json")
  }
}
