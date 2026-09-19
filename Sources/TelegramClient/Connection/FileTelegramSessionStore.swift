import Crypto
import Foundation
import NIOMTProtoEncryption

/// Stores authorized sessions and datacenter lists in a private directory.
///
/// Pass one instance to ``TelegramConnection`` with a stable `sessionScope` to
/// resume the same account after restarting. Session keys already distinguish
/// scopes and datacenters; filenames hash those opaque keys so even long keys
/// or keys containing path separators cannot escape the directory.
///
/// Session files contain credentials. The directory is restricted to its owner
/// (`0700`) and files are restricted to owner read/write (`0600`). Writes replace
/// one complete JSON file atomically. Missing files return nil; unreadable or
/// corrupt files throw instead of silently spending another authorization.
///
/// Coordinate access through one store instance per directory within a process.
/// Concurrent processes must use separate directories. This store does not
/// encrypt files; use an encrypted filesystem when encryption at rest is needed.
public actor FileTelegramSessionStore: TelegramSessionStore {
  private struct Session: Codable {
    var authKey: Data
    var serverSalt: Int64
    var expiresAt: Int32
    var accountID: Int64
  }

  private let directory: URL

  /// Creates the directory if necessary and restricts access to its owner.
  /// Use a dedicated directory because its permissions are set to `0700`.
  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  public func session(for key: String) throws -> CachedTelegramSession? {
    guard let saved = try read(Session.self, namespace: "session", key: key) else { return nil }
    return CachedTelegramSession(
      session: MTProtoStoredSession(
        authKey: saved.authKey, serverSalt: saved.serverSalt, expiresAt: saved.expiresAt),
      accountID: saved.accountID)
  }

  public func save(
    _ session: MTProtoStoredSession, accountID: Int64, for key: String
  ) throws {
    try write(
      Session(
        authKey: session.authKey, serverSalt: session.serverSalt,
        expiresAt: session.expiresAt, accountID: accountID),
      namespace: "session", key: key)
  }

  public func deleteSession(for key: String) throws {
    do {
      try FileManager.default.removeItem(at: url(namespace: "session", key: key))
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      // Deleting a missing session is idempotent.
    }
  }

  public func datacenterList(for scope: String) throws -> StoredDatacenterList? {
    try read(StoredDatacenterList.self, namespace: "datacenters", key: scope)
  }

  public func saveDatacenterList(_ list: StoredDatacenterList, for scope: String) throws {
    try write(list, namespace: "datacenters", key: scope)
  }

  private func read<T: Decodable>(_ type: T.Type, namespace: String, key: String) throws -> T? {
    let data: Data
    do {
      data = try Data(contentsOf: url(namespace: namespace, key: key))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    }
    return try JSONDecoder().decode(type, from: data)
  }

  private func write<T: Encodable>(_ value: T, namespace: String, key: String) throws {
    let destination = url(namespace: namespace, key: key)
    try JSONEncoder().encode(value).write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  private func url(namespace: String, key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("\(namespace)-\(digest).json")
  }
}
