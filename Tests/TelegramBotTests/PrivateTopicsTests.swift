#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import MTProtoClientKit
import TelegramBot
import TelegramClient
import TelegramSchema
import Testing

@Suite struct PrivateTopicsTests {
  @Test(arguments: PrivateTopicCreationRefusal.allCases, [400, 403, 500])
  func creationRefusalsRoundTrip(fact: PrivateTopicCreationRefusal, code: Int32) {
    #expect(PrivateTopicCreationRefusal(MTProtoRPCError(code: code, message: fact.rawValue)) == fact)
    #expect(PrivateTopicCreationRefusal(fact as any Error) == fact)
    #expect(PrivateTopicCreationRefusal(errorMessage: fact.rawValue) == fact)
    #expect(String(describing: fact) == fact.rawValue)
  }

  @Test(arguments: PrivateChatUnreachable.allCases, [400, 403, 500])
  func unreachableUsersRoundTrip(fact: PrivateChatUnreachable, code: Int32) {
    #expect(PrivateChatUnreachable(MTProtoRPCError(code: code, message: fact.rawValue)) == fact)
    #expect(PrivateChatUnreachable(fact as any Error) == fact)
    #expect(PrivateChatUnreachable(errorMessage: fact.rawValue) == fact)
    #expect(String(describing: fact) == fact.rawValue)
  }

  @Test func errorFactSetsAreDisjointAndRejectNonmembers() {
    let refusals = Set(PrivateTopicCreationRefusal.allCases.map(\.rawValue))
    let unreachable = Set(PrivateChatUnreachable.allCases.map(\.rawValue))
    let gone = Set(ForumTopicGone.allCases.map(\.rawValue))
    #expect(refusals.isDisjoint(with: unreachable))
    #expect(refusals.isDisjoint(with: gone))
    #expect(unreachable.isDisjoint(with: gone))
    for message in refusals.union(unreachable).union(gone).union(["UNKNOWN", "", "FLOOD_WAIT_5"]) {
      let rpc = MTProtoRPCError(code: 400, message: message)
      #expect((PrivateTopicCreationRefusal(rpc) != nil) == refusals.contains(message))
      #expect((PrivateChatUnreachable(rpc) != nil) == unreachable.contains(message))
      #expect((ForumTopicGone(rpc) != nil) == gone.contains(message))
    }
    #expect(PrivateTopicCreationRefusal(CancellationError()) == nil)
    #expect(PrivateChatUnreachable(CancellationError()) == nil)
    #expect(PrivateTopicCreationRefusal(PrivateChatUnreachable.userIsBlocked) == nil)
    #expect(PrivateChatUnreachable(PrivateTopicCreationRefusal.forbidden) == nil)
    #expect(ForumTopicGone(PrivateTopicCreationRefusal.wrongHome) == nil)
  }

  @Test(arguments: PrivateTopicCreationRefusal.allCases, [400, 403, 500])
  func createThrowsTypedRefusals(fact: PrivateTopicCreationRefusal, code: Int32) async throws {
    let rpc = MTProtoRPCError(code: code, message: fact.rawValue)
    let client = PrivateTopicClient(api: TLClient(transport: CannedTransport { _ in throw rpc }))
    await #expect(throws: fact) {
      try await client.create(with: .inputPeerSelf(.init()), userID: 7, title: "Topic", randomID: 99)
    }
    // The same refusal on a non-creation operation remains the original RPC error.
    do {
      _ = try await client.rename(1, with: .inputPeerSelf(.init()), title: "Topic")
      Issue.record("Expected rename to fail")
    } catch {
      let original = try #require(error as? MTProtoRPCError)
      #expect(original.code == rpc.code && original.message == rpc.message)
    }
  }

  @Test(arguments: PrivateChatUnreachable.allCases.map(\.rawValue)
    + ForumTopicGone.allCases.map(\.rawValue) + ["INTERNAL", "UNKNOWN", "FLOOD_WAIT_5"])
  func createPreservesOtherRPCErrors(message: String) async throws {
    let rpc = MTProtoRPCError(code: 400, message: message)
    let client = PrivateTopicClient(api: TLClient(transport: CannedTransport { _ in throw rpc }))
    do {
      _ = try await client.create(with: .inputPeerSelf(.init()), userID: 7, title: "Topic", randomID: 99)
      Issue.record("Expected creation to fail")
    } catch {
      let original = try #require(error as? MTProtoRPCError)
      #expect(original.code == rpc.code && original.message == rpc.message)
    }
  }

  @Test func createPreservesOtherErrorsByIdentityAndCancellation() async {
    final class TransportFailure: Error {}
    let failure = TransportFailure()
    let client = PrivateTopicClient(api: TLClient(transport: CannedTransport { _ in throw failure }))
    do {
      _ = try await client.create(with: .inputPeerSelf(.init()), userID: 7, title: "Topic", randomID: 99)
      Issue.record("Expected creation to fail")
    } catch { #expect(error as? TransportFailure === failure) }
    let cancelled = PrivateTopicClient(api: TLClient(transport: CannedTransport { _ in throw CancellationError() }))
    await #expect(throws: CancellationError.self) {
      try await cancelled.create(with: .inputPeerSelf(.init()), userID: 7, title: "Topic", randomID: 99)
    }
  }

  private func creation(_ id: Int32, user: Int64 = 7) -> TL.UpdateType {
    .updateNewMessage(
      .init(
        message: .messageService(
          .init(
            id: id, peerId: .peerUser(.init(userId: user)),
            date: 1, action: .messageActionTopicCreate(.init(title: "Topic", iconColor: 0x6FB9F0)))),
        pts: 1, ptsCount: 1))
  }

  private func updates(_ list: [TL.UpdateType]) -> TL.UpdatesType {
    .updates(.init(updates: list, users: [], chats: [], date: 1, seq: 1))
  }

  @Test func createdTopicMatchesRandomIDAndUserRegardlessOfUpdateOrder() {
    let list: [TL.UpdateType] = [
      creation(10, user: 8), creation(11), creation(12),
      .updateMessageID(.init(id: 12, randomId: 99)), .updateMessageID(.init(id: 11, randomId: 98)),
    ]
    #expect(PrivateTopics.createdTopicID(in: updates(list), user: 7, randomID: 99) == 12)
    #expect(PrivateTopics.createdTopicID(in: updates(list.reversed()), user: 7, randomID: 99) == 12)
    #expect(PrivateTopics.createdTopicID(in: updates(list), user: 8, randomID: 99) == nil)
    #expect(PrivateTopics.createdTopicID(in: updates(list), user: 9, randomID: 99) == nil)
    #expect(
      PrivateTopics.createdTopicID(
        in: updates([creation(11), .updateMessageID(.init(id: 12, randomId: 99))]),
        user: 7, randomID: 99) == nil)
    let unrelated: [TL.UpdateType] = [creation(11), .updateMessageID(.init(id: 11, randomId: 98))]
    #expect(PrivateTopics.createdTopicID(in: updates(unrelated), user: 7, randomID: 99) == nil)
    #expect(
      PrivateTopics.createdTopicID(in: updates(unrelated + [creation(12)]), user: 7, randomID: 99)
        == 12)
  }

  @Test func privateTopicIDComesFromTheCreationMessagesReplyHeader() {
    // Recorded from Telegram: a bot's private topic is not numbered like messages.
    let created = TL.MessageType.messageService(
      .init(
        out: true, id: 23, peerId: .peerUser(.init(userId: 7)),
        replyTo: .messageReplyHeader(.init(forumTopic: true, replyToTopId: 387797)), date: 1,
        action: .messageActionTopicCreate(.init(title: "Topic", iconColor: 0x6FB9F0))))
    let list: [TL.UpdateType] = [
      .updateMessageID(.init(id: 23, randomId: 99)),
      .updateNewMessage(.init(message: created, pts: 1, ptsCount: 1)),
    ]
    #expect(PrivateTopics.createdTopicID(in: updates(list), user: 7, randomID: 99) == 387797)
    #expect(ForumTopics.topicID(of: created) == 387797)
    let inTopic = TL.MessageType.message(
      .init(
        id: 26, peerId: .peerUser(.init(userId: 7)),
        replyTo: .messageReplyHeader(
          .init(forumTopic: true, replyToMsgId: 23, replyToTopId: 387797)), date: 1, message: "Hi"))
    #expect(ForumTopics.topicID(of: inTopic) == 387797)
  }

  @Test func createdTopicFallsBackToServiceMessageAcrossUpdateContainers() {
    let containers: [TL.UpdatesType] = [
      updates([creation(10, user: 8), creation(11)]),
      .updatesCombined(
        .init(updates: [creation(11)], users: [], chats: [], date: 1, seqStart: 1, seq: 1)),
      .updateShort(.init(update: creation(11), date: 1)),
    ]
    for container in containers {
      #expect(PrivateTopics.createdTopicID(in: container, user: 7, randomID: 99) == 11)
    }
    #expect(
      PrivateTopics.createdTopicID(in: updates([creation(10, user: 8)]), user: 7, randomID: 99)
        == nil)
    #expect(
      PrivateTopics.createdTopicID(in: .updatesTooLong(.init()), user: 7, randomID: 99) == nil)
    let ordinary = TL.UpdateType.updateNewMessage(
      .init(
        message: .message(
          .init(
            id: 11,
            peerId: .peerUser(.init(userId: 7)), date: 1, message: "Topic")), pts: 1, ptsCount: 1))
    #expect(PrivateTopics.createdTopicID(in: updates([ordinary]), user: 7, randomID: 99) == nil)
  }

  @Test func createdTopicRecordsDistinguishUserMessageAndTopicIDs() async throws {
    let message = TL.MessageType.messageService(.init(out: true, id: 23,
      peerId: .peerUser(.init(userId: 7)),
      replyTo: .messageReplyHeader(.init(forumTopic: true, replyToTopId: 300)), date: 10,
      action: .messageActionTopicCreate(.init(title: "Topic", iconColor: 0))))
    let response = TL.Messages.MessagesType.messages(.init(messages: [message], topics: [], chats: [], users: []))
    let client = PrivateTopicClient(
      api: TLClient(transport: CannedTransport([response.tlSerialized()])))
    let result = try await client.createdTopics(among: [23])
    #expect(result.topics == [.init(userID: 7, creationMessageID: 23, topicID: 300)])
    #expect(result.topics.first?.userID == 7 && result.topics.first?.creationMessageID == 23 && result.topics.first?.topicID == 300)
    #expect(result.dates == [10])
  }
}
