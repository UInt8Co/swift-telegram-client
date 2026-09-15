import TelegramSchema
import Testing

@testable import TelegramClient

@Suite struct UpdateCursorTests {
  private let channelID: Int64 = 42

  @Test func differenceSliceWrapsMessagesAndAdvancesIntermediateState() throws {
    let message = TL.MessageType.message(
      TL.Message(
        post: true, id: 7, peerId: .peerChannel(TL.PeerChannel(channelId: channelID)),
        date: 100, message: "hello"))
    let state = TL.Updates.State(pts: 20, qts: 2, date: 101, seq: 3, unreadCount: 0)
    let decoded = try DifferenceDecoder.decode(
      .differenceSlice(
        TL.Updates.DifferenceSlice(
          newMessages: [message], newEncryptedMessages: [], otherUpdates: [],
          chats: [], users: [], intermediateState: state)),
      from: .beginning, sourceDescription: "@source")

    #expect(decoded.cursor == UpdateCursor(state))
    #expect(decoded.hasMore)
    #expect(decoded.updates.count == 1)
    guard case .updateNewChannelMessage(let update) = decoded.updates[0] else {
      Issue.record("message was not wrapped as updateNewChannelMessage")
      return
    }
    #expect(update.message == message)
  }

  @Test func emptyDifferenceKeepsPtsAndQts() throws {
    let cursor = UpdateCursor(pts: 9, qts: 8, date: 7, seq: 6)
    let decoded = try DifferenceDecoder.decode(
      .differenceEmpty(TL.Updates.DifferenceEmpty(date: 10, seq: 11)),
      from: cursor, sourceDescription: "42")
    #expect(decoded.cursor == UpdateCursor(pts: 9, qts: 8, date: 10, seq: 11))
    #expect(decoded.updates.isEmpty)
    #expect(!decoded.hasMore)
  }

  @Test func differenceWrapsPrivateMessagesForCommandHandling() throws {
    let message = TL.MessageType.message(
      TL.Message(
        id: 8, fromId: .peerUser(TL.PeerUser(userId: 9)),
        peerId: .peerUser(TL.PeerUser(userId: 9)), date: 100,
        message: "hello"))
    let state = TL.Updates.State(pts: 20, qts: 0, date: 101, seq: 3, unreadCount: 0)
    let decoded = try DifferenceDecoder.decode(
      .difference(
        TL.Updates.Difference(
          newMessages: [message], newEncryptedMessages: [], otherUpdates: [],
          chats: [], users: [], state: state)),
      from: .beginning, sourceDescription: "commands")
    guard case .updateNewMessage(let update) = decoded.updates.first else {
      Issue.record("private message was not wrapped as updateNewMessage")
      return
    }
    #expect(update.message == message)
  }

  @Test func filtersChannelCRUDWithoutLeakingOtherChannels() {
    let ours = message(id: 1, channelID: channelID)
    let other = message(id: 2, channelID: 99)
    let updates: [TL.UpdateType] = [
      .updateNewChannelMessage(TL.UpdateNewChannelMessage(message: ours, pts: 1, ptsCount: 1)),
      .updateEditChannelMessage(TL.UpdateEditChannelMessage(message: other, pts: 2, ptsCount: 1)),
      .updateDeleteChannelMessages(
        TL.UpdateDeleteChannelMessages(channelId: channelID, messages: [1], pts: 3, ptsCount: 1)),
      .updateUserStatus(
        TL.UpdateUserStatus(
          userId: 4, status: .userStatusOnline(TL.UserStatusOnline(expires: 100)))),
    ]
    let filtered = ChannelUpdateFilter.updates(updates, forChannelID: channelID)
    #expect(filtered == [updates[0], updates[2]])
  }

  @Test func keepsPinsAndDropsAnotherChannelsPins() {
    let updates: [TL.UpdateType] = [
      .updatePinnedChannelMessages(
        TL.UpdatePinnedChannelMessages(
          pinned: true, channelId: channelID, messages: [1], pts: 4, ptsCount: 0)),
      .updatePinnedChannelMessages(
        TL.UpdatePinnedChannelMessages(
          pinned: true, channelId: 99, messages: [1], pts: 5, ptsCount: 0)),
    ]
    #expect(ChannelUpdateFilter.updates(updates, forChannelID: channelID) == [updates[0]])
  }

  @Test func tooLongDifferenceFailsBackfill() {
    #expect(throws: TelegramClientError.historyTooLong("@source")) {
      try DifferenceDecoder.decode(
        .differenceTooLong(TL.Updates.DifferenceTooLong(pts: 100)),
        from: .beginning, sourceDescription: "@source")
    }
  }

  private func message(id: Int32, channelID: Int64) -> TL.MessageType {
    .message(
      TL.Message(
        post: true, id: id, peerId: .peerChannel(TL.PeerChannel(channelId: channelID)),
        date: 1, message: "message"))
  }
}
