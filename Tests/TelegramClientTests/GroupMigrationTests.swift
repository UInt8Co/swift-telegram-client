import TelegramClient
import TelegramSchema
import Testing

@Suite struct GroupMigrationTests {
  private let old = TL.PeerType.peerChat(.init(chatId: 123))
  private let new = TL.PeerType.peerChannel(.init(channelId: 456))

  @Test func bothServiceActionsAndAllMessageUpdates() {
    let messages: [TL.MessageType] = [
      .messageService(
        .init(
          id: 11, peerId: old, date: 1, action: .messageActionChatMigrateTo(.init(channelId: 456)))),
      .messageService(
        .init(
          id: 1, peerId: new, date: 1,
          action: .messageActionChannelMigrateFrom(.init(title: "old", chatId: 123)))),
    ]
    for message in messages {
      let expected = GroupMigration(chatID: 123, channelID: 456)
      #expect(GroupMigration(message: message) == expected)
      for update: TL.UpdateType in [
        .updateNewMessage(.init(message: message, pts: 1, ptsCount: 1)),
        .updateNewChannelMessage(.init(message: message, pts: 1, ptsCount: 1)),
        .updateEditMessage(.init(message: message, pts: 1, ptsCount: 1)),
        .updateEditChannelMessage(.init(message: message, pts: 1, ptsCount: 1)),
      ] { #expect(GroupMigration(update: update) == expected) }
    }
  }

  @Test func chatMetadataAndUpdateChatNeedMatchingRefreshedPeer() {
    var chat = TL.Chat(
      id: 123, title: "old", photo: .chatPhotoEmpty(.init()), participantsCount: 2, date: 1,
      version: 1)
    #expect(GroupMigration(chat: .chat(chat)) == nil)
    chat.migratedTo = .inputChannel(.init(channelId: 456, accessHash: 42))
    let expected = GroupMigration(chatID: 123, channelID: 456)
    #expect(GroupMigration(chat: .chat(chat)) == expected)
    #expect(
      GroupMigration(update: .updateChat(.init(chatId: 123)), refreshedChat: .chat(chat))
        == expected)
    #expect(
      GroupMigration(update: .updateChat(.init(chatId: 789)), refreshedChat: .chat(chat)) == nil)
    #expect(GroupMigration(update: .updateChat(.init(chatId: 123))) == nil)
    chat.migratedTo = .inputChannelFromMessage(
      .init(peer: .inputPeerChat(.init(chatId: 123)), msgId: 11, channelId: 456))
    #expect(GroupMigration(chat: .chat(chat)) == expected)
    chat.migratedTo = .inputChannelEmpty(.init())
    #expect(GroupMigration(chat: .chat(chat)) == nil)
    #expect(GroupMigration(chat: .chatForbidden(.init(id: 123, title: "old"))) == nil)
  }

  @Test func wrongContextsAndInvalidIDsAreNotMigrations() {
    #expect(GroupMigration(chatID: 0, channelID: 456) == nil)
    #expect(GroupMigration(chatID: 123, channelID: -1) == nil)
    #expect(
      GroupMigration(message: .message(.init(id: 1, peerId: old, date: 1, message: "migrate")))
        == nil)
    #expect(
      GroupMigration(
        message: .messageService(
          .init(
            id: 1, peerId: new, date: 1,
            action: .messageActionChatMigrateTo(.init(channelId: 456))))) == nil)
    #expect(
      GroupMigration(
        message: .messageService(
          .init(
            id: 1, peerId: old, date: 1,
            action: .messageActionChannelMigrateFrom(.init(title: "old", chatId: 123))))) == nil)
  }
}
