import NIOMTProtoEncryption
import Testing

@testable import TelegramClient

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct FileTelegramSessionStoreTests {
  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  /// `attributesOfItem` boxes the mode as a `UInt` under FoundationEssentials
  /// and as a bridged `NSNumber` under the umbrella Foundation.
  private func permissions(ofItemAtPath path: String) throws -> Int? {
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
    return mode as? Int ?? (mode as? UInt).map { Int($0) }
  }

  @Test("sessions persist account identity, salt, expiry, and namespace separation")
  func sessionsSurviveReopening() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileTelegramSessionStore(directory: directory)
    let key = TelegramConnection.sessionKey(scope: "first", dcID: 2)
    let otherAccount = TelegramConnection.sessionKey(scope: "second", dcID: 2)
    let otherDC = TelegramConnection.sessionKey(scope: "first", dcID: 4)
    let session = MTProtoStoredSession(
      authKey: Data(repeating: 0xA5, count: 256), serverSalt: -123, expiresAt: 2_000_000_000)
    try await store.save(session, accountID: 42, for: key)
    let reopened = try FileTelegramSessionStore(directory: directory)
    #expect(try await reopened.session(for: key) == CachedTelegramSession(session: session, accountID: 42))
    #expect(try await reopened.session(for: otherAccount) == nil)
    #expect(try await reopened.session(for: otherDC) == nil)
    try await reopened.deleteSession(for: key)
    try await reopened.deleteSession(for: key)
    #expect(try await reopened.session(for: key) == nil)
  }

  @Test("datacenter lists survive reopening and do not collide with session keys")
  func datacenterListsAreSeparate() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileTelegramSessionStore(directory: directory)
    let list = StoredDatacenterList(datacenters: [], expiresAt: Date(timeIntervalSince1970: 12345))
    try await store.saveDatacenterList(list, for: "same-key")
    let session = MTProtoStoredSession(authKey: Data(repeating: 1, count: 256), serverSalt: 4)
    try await store.save(session, accountID: 5, for: "same-key")
    let reopened = try FileTelegramSessionStore(directory: directory)
    #expect(try await reopened.datacenterList(for: "same-key") == list)
    #expect(try await reopened.datacenterList(for: "another-key") == nil)
    #expect(try await reopened.session(for: "same-key")?.session == session)
  }

  @Test("opaque long keys remain contained and credential files have private permissions")
  func keysCannotEscapeDirectory() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileTelegramSessionStore(directory: directory)
    let key = "../../" + String(repeating: "opaque/scope:", count: 500)
    let session = MTProtoStoredSession(authKey: Data(repeating: 3, count: 256), serverSalt: 0)
    try await store.save(session, accountID: 6, for: key)
    #expect(try await store.session(for: key)?.session == session)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.count == 1)
    #expect(try permissions(ofItemAtPath: directory.path) == 0o700)
    for name in names {
      #expect(name.utf8.count < 255)
      let file = directory.appendingPathComponent(name)
      #expect(try permissions(ofItemAtPath: file.path) == 0o600)
    }
  }

  @Test("corrupt persisted credentials fail instead of appearing to be a missing session")
  func corruptedSessionsThrow() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileTelegramSessionStore(directory: directory)
    let session = MTProtoStoredSession(authKey: Data(repeating: 3, count: 256), serverSalt: 0)
    try await store.save(session, accountID: 6, for: "key")
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let file = directory.appendingPathComponent(try #require(names.first))
    try Data("not JSON".utf8).write(to: file)
    await #expect(throws: DecodingError.self) { try await store.session(for: "key") }
  }
}
