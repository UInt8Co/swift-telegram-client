import Foundation
import NIOMTProtoEncryption
import Testing

@testable import TelegramClient

@Suite struct FileTelegramSessionStoreTests {
  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    for file in files {
      #expect(file.lastPathComponent.utf8.count < 255)
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
  }

  @Test("corrupt persisted credentials fail instead of appearing to be a missing session")
  func corruptedSessionsThrow() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileTelegramSessionStore(directory: directory)
    let session = MTProtoStoredSession(authKey: Data(repeating: 3, count: 256), serverSalt: 0)
    try await store.save(session, accountID: 6, for: "key")
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let file = try #require(files.first)
    try Data("not JSON".utf8).write(to: file)
    await #expect(throws: DecodingError.self) { try await store.session(for: "key") }
  }
}
