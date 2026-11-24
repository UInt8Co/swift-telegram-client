#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import MTProtoClientKit
import Synchronization
import TelegramBot
import TelegramClient
import TelegramSchema
import Testing

@Suite struct BusinessConnectionsTests {
  static let connection = TL.BotBusinessConnection(
    disabled: false, connectionId: "c1", userId: 7, dcId: 4, date: 100,
    rights: .init(reply: true, deleteReceivedMessages: true))

  @Test func decodesConnectionsWithRightsAndDisabledState() throws {
    let update = TL.UpdateType.updateBotBusinessConnect(.init(connection: Self.connection, qts: 1))
    guard case .connection(let decoded)? = BusinessUpdate(update) else {
      Issue.record("not a connection update")
      return
    }
    #expect(
      decoded
        == BusinessConnection(
          id: "c1", user: .init(kind: .user, id: 7), dcID: 4, date: 100, isEnabled: true,
          rights: [.reply, .deleteReceivedMessages]))
    var disabled = Self.connection
    disabled.disabled = true
    disabled.rights = nil
    let off = BusinessConnection(disabled)
    #expect(!off.isEnabled && off.rights.isEmpty)
    #expect(BusinessUpdate(.updateBotBusinessConnect(.init(connection: disabled, qts: 2)))?.connectionID == "c1")
  }

  @Test func decodesMessagesWithTheirChatAndSender() throws {
    let partner = TL.PeerType.peerUser(.init(userId: 9))
    let incoming = TL.MessageType.message(.init(id: 5, peerId: partner, date: 1, message: "hi"))
    let reply = TL.MessageType.message(.init(id: 4, peerId: partner, date: 1, message: "earlier"))
    guard
      case .newMessage(let message)? = BusinessUpdate(
        .updateBotNewBusinessMessage(
          .init(connectionId: "c1", message: incoming, replyToMessage: reply, qts: 3)))
    else {
      Issue.record("not a new message")
      return
    }
    #expect(message.connectionID == "c1" && message.id == 5 && !message.isOutgoing)
    #expect(message.chat == .init(kind: .user, id: 9) && message.sender == .init(kind: .user, id: 9))
    #expect(message.replyTo != nil)

    let owner = TL.PeerType.peerUser(.init(userId: 7))
    let named = TL.MessageType.message(.init(out: true, id: 6, fromId: owner, peerId: partner, date: 1, message: "yo"))
    guard
      case .editedMessage(let edited)? = BusinessUpdate(
        .updateBotEditBusinessMessage(.init(connectionId: "c1", message: named, qts: 4)))
    else {
      Issue.record("not an edited message")
      return
    }
    #expect(edited.isOutgoing && edited.sender == .init(kind: .user, id: 7) && edited.replyTo == nil)
    let unnamed = BusinessMessage(
      connectionID: "c1", message: .message(.init(out: true, id: 7, peerId: partner, date: 1, message: "")),
      replyTo: nil)
    #expect(unnamed.sender == nil && unnamed.chat == .init(kind: .user, id: 9))

    guard
      case .deletedMessages(let id, let chat, let ids)? = BusinessUpdate(
        .updateBotDeleteBusinessMessage(.init(connectionId: "c2", peer: partner, messages: [5, 6], qts: 5)))
    else {
      Issue.record("not a deletion")
      return
    }
    #expect(id == "c2" && chat == .init(kind: .user, id: 9) && ids == [5, 6])
    #expect(BusinessUpdate(.updateBotStopped(.init(userId: 1, date: 1, stopped: true, qts: 6))) == nil)
  }

  @Test func deletesForBothSidesOnTheConnectionsDatacenter() async throws {
    let home = CannedTransport([])
    let remote = CannedTransport([TL.Messages.AffectedMessages(pts: 50, ptsCount: 2).tlSerialized()])
    let asked = Mutex<[Int32]>([])
    let client = BusinessConnectionClient(api: TLClient(transport: home)) { dc in
      asked.withLock { $0.append(dc) }
      return TLClient(transport: remote)
    }
    let connection = BusinessConnection(Self.connection)
    try await client.deleteMessages([], via: connection)
    #expect(remote.requests.isEmpty && asked.withLock { $0 }.isEmpty)
    try await client.deleteMessages([5, 6], via: connection)
    #expect(asked.withLock { $0 } == [4] && home.requests.isEmpty)
    let request = try #require(
      remote.requests(TL.InvokeWithBusinessConnection<TL.Messages.DeleteMessages>.self).first)
    #expect(request.connectionId == "c1" && request.query.revoke && request.query.id == [5, 6])
  }

  @Test func fetchesAMissedConnection() async throws {
    let other = TL.BotBusinessConnection(connectionId: "c0", userId: 8, dcId: 2, date: 1)
    let updates = TL.UpdatesType.updates(
      .init(
        updates: [
          .updateBotBusinessConnect(.init(connection: other, qts: 1)),
          .updateBotBusinessConnect(.init(connection: Self.connection, qts: 2)),
        ], users: [.user(.init(id: 7))], chats: [], date: 1, seq: 0))
    let home = CannedTransport([updates.tlSerialized(), TL.UpdatesType.updatesTooLong(.init()).tlSerialized()])
    let client = BusinessConnectionClient(api: TLClient(transport: home)) { _ in
      Issue.record("lookups stay on the home datacenter")
      return TLClient(transport: home)
    }
    #expect(try await client.connection(id: "c1") == BusinessConnection(Self.connection))
    #expect(try await client.connection(id: "c1") == nil)
    #expect(home.requests(TL.Account.GetBotBusinessConnection.self).map(\.connectionId) == ["c1", "c1"])
  }

  @Test func recognizesConnectionFailures() {
    for fact in BusinessConnectionFailure.allCases {
      #expect(BusinessConnectionFailure(MTProtoRPCError(code: 400, message: fact.rawValue)) == fact)
      #expect(BusinessConnectionFailure(fact) == fact)
    }
    #expect(BusinessConnectionFailure(MTProtoRPCError(code: 400, message: "PEER_ID_INVALID")) == nil)
  }
}
