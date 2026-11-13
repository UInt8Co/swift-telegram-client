import TelegramSchema
import Testing

@testable import TelegramClient

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct PeerCacheTests {
  private static func channel(hash: Int64, min: Bool = false) -> Data {
    TL.Messages.ChatsType.chats(
      TL.Messages.Chats(chats: [
        .channel(
          TL.Channel(
            megagroup: true, min: min, id: 42, accessHash: hash, title: "Group",
            photo: .chatPhotoEmpty(TL.ChatPhotoEmpty()), date: 1))
      ])
    ).tlSerialized()
  }

  @Test("bot lookups use zero once and retain each session's full hash for writes")
  func fullHashesBelongToTheirSession() async throws {
    let first = CannedTransport([Self.channel(hash: 123)])
    let second = CannedTransport([Self.channel(hash: 456)])
    let a = PeerCache(using: TLClient(transport: first), lookup: .byID)
    let b = PeerCache(using: TLClient(transport: second), lookup: .byID)

    #expect(
      try await a.channel(42).inputPeer
        == .inputPeerChannel(
          TL.InputPeerChannel(channelId: 42, accessHash: 123)))
    #expect(try await b.channel(42).accessHash == 456)
    #expect(try await a.channel(42).accessHash == 123)
    #expect(first.requests.count == 1)
    let request = try #require(first.requests.first as? TL.Channels.GetChannels)
    #expect(
      request.id == [
        .inputChannel(TL.InputChannel(channelId: 42, accessHash: 0))
      ])
  }

  @Test("invalidating a rejected channel obtains a fresh reference")
  func refreshesRejectedReference() async throws {
    let transport = CannedTransport([Self.channel(hash: 123), Self.channel(hash: 456)])
    let peers = PeerCache(using: TLClient(transport: transport), lookup: .byID)
    #expect(try await peers.channel(42).accessHash == 123)
    await peers.invalidateChannel(42)
    #expect(try await peers.channel(42).accessHash == 456)
    #expect(transport.requests.count == 2)
  }

  @Test("a failed lookup does not hide a peer that becomes available")
  func retriesFailedLookup() async throws {
    let empty = TL.Messages.ChatsType.chats(TL.Messages.Chats(chats: [])).tlSerialized()
    let transport = CannedTransport([empty, Self.channel(hash: 123)])
    let peers = PeerCache(using: TLClient(transport: transport), lookup: .byID)
    await #expect(throws: TelegramClientError.self) { try await peers.channel(42) }
    #expect(try await peers.channel(42).accessHash == 123)
  }

  @Test("a min hash stays a zero fallback and does not prevent learning a full hash")
  func doesNotCacheMinHashes() async throws {
    let transport = CannedTransport([
      Self.channel(hash: 999, min: true), Self.channel(hash: 123),
    ])
    let peers = PeerCache(using: TLClient(transport: transport), lookup: .byID)
    #expect(try await peers.channel(42).accessHash == 0)
    #expect(try await peers.channel(42).accessHash == 123)
    #expect(try await peers.channel(42).accessHash == 123)
    #expect(transport.requests.count == 2)
  }

  @Test("user and channel IDs do not collide, and user hashes can be refreshed")
  func separatesPeerKinds() async throws {
    let transport = CannedTransport([
      Self.channel(hash: 123),
      [TL.UserType.user(TL.User(id: 42, accessHash: 456))].tlSerialized(),
      [TL.UserType.user(TL.User(id: 42, accessHash: 789))].tlSerialized(),
    ])
    let peers = PeerCache(using: TLClient(transport: transport), lookup: .byID)
    #expect(try await peers.channel(42).accessHash == 123)
    #expect(try await peers.user(42).accessHash == 456)
    #expect(try await peers.user(42).accessHash == 456)
    await peers.invalidateUser(42)
    #expect(try await peers.user(42).accessHash == 789)
    #expect(try await peers.channel(42).accessHash == 123)
    let request = try #require(transport.requests[1] as? TL.Users.GetUsers)
    #expect(request.id == [.inputUser(TL.InputUser(userId: 42, accessHash: 0))])
    #expect(transport.requests.count == 3)
  }
}
