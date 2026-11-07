import TelegramBot
import TelegramClient
import TelegramSchema
import Testing

@Suite struct PrivateTopicsTests {
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

}
