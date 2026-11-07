#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIOMTProtoEncryption
import TelegramClient
import Testing

@Suite struct SessionInspectionTests {
  @Test func inspectsMissingMatchingMismatchedPermanentAndTemporarySessions() async throws {
    let sessions = InMemoryTelegramSessionStore()
    let ids: [Int32] = [5, 1, 2, 3, 4, 5]
    let missing = await SessionInspection.inspect(sessions: sessions, scope: "client-123",
      expectedAccountID: 123, dcIDs: ids)
    #expect(missing.map(\.dcID) == [1, 2, 3, 4, 5])
    #expect(missing.allSatisfy { $0.status == .missing })
    for (dc, account, expiry) in [(Int32(2), Int64(123), Int32(0)), (3, 456, 0), (4, 123, 130), (5, 123, 70)] {
      try await sessions.save(.init(authKey: Data(repeating: 42, count: 256), serverSalt: 99, expiresAt: expiry),
        accountID: account, for: TelegramConnection.sessionKey(scope: "client-123", dcID: dc))
    }
    let results = await SessionInspection.inspect(sessions: sessions, scope: "client-123",
      expectedAccountID: 123, dcIDs: ids, now: Date(timeIntervalSince1970: 100))
    #expect(results.map(\.status) == [.missing, .stored(accountMatches: true, expiresInSeconds: nil),
      .stored(accountMatches: false, expiresInSeconds: nil), .stored(accountMatches: true, expiresInSeconds: 30),
      .stored(accountMatches: true, expiresInSeconds: -30)])
  }

  @Test func unreadableEntryDoesNotExposeContentsOrAbortOtherDatacenters() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessions = try FileTelegramSessionStore(directory: directory)
    let key = TelegramConnection.sessionKey(scope: "client-123", dcID: 5)
    try await sessions.save(.init(authKey: Data(repeating: 42, count: 256), serverSalt: 99), accountID: 123, for: key)
    let file = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path).first.map { directory.appendingPathComponent($0) })
    let secret = Data("private invalid session".utf8)
    try secret.write(to: file)
    let results = await SessionInspection.inspect(sessions: sessions, scope: "client-123", expectedAccountID: 123,
      dcIDs: [1, 5])
    #expect(results.map(\.status) == [.missing, .unreadable])
    #expect(!String(describing: results).contains("private"))
    #expect(try Data(contentsOf: file) == secret)
  }
}
