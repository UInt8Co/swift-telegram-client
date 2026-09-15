import MTProtoClientKit
import TelegramSchema
import Testing

@testable import TelegramClient

@Suite struct ChannelDifferenceTests {
  private static let channelID: Int64 = 4_242

  private static func post(_ id: Int32) -> TL.MessageType {
    .message(
      TL.Message(
        post: true, id: id, peerId: .peerChannel(TL.PeerChannel(channelId: channelID)),
        date: 1_000 + id, message: "post \(id)"))
  }

  private static func dialog(pts: Int32?) -> TL.DialogType {
    .dialog(
      TL.Dialog(
        peer: .peerChannel(TL.PeerChannel(channelId: channelID)), topMessage: 9,
        readInboxMaxId: 0, readOutboxMaxId: 0, unreadCount: 0, unreadMentionsCount: 0,
        unreadReactionsCount: 0, unreadPollVotesCount: 0,
        notifySettings: TL.PeerNotifySettings(), pts: pts))
  }

  @Test("an empty difference carries the channel's position and nothing else")
  func decodesAnEmptyDifference() {
    let batch = ChannelDifferenceDecoder.decode(
      .channelDifferenceEmpty(
        TL.Updates.ChannelDifferenceEmpty(final: true, pts: 120, timeout: 60)))

    #expect(batch.updates.isEmpty)
    #expect(batch.pts == 120)
    #expect(batch.isFinal)
    #expect(batch.timeout == 60)
    #expect(!batch.skippedGap)
  }

  @Test("messages become channel-message updates, other updates ride along")
  func decodesADifference() throws {
    let deletion = TL.UpdateType.updateDeleteChannelMessages(
      TL.UpdateDeleteChannelMessages(
        channelId: Self.channelID, messages: [3], pts: 122, ptsCount: 1))
    let batch = ChannelDifferenceDecoder.decode(
      .channelDifference(
        TL.Updates.ChannelDifference(
          final: false, pts: 123, timeout: 60,
          newMessages: [Self.post(1), Self.post(2)], otherUpdates: [deletion],
          chats: [], users: [.user(TL.User(id: 7, firstName: "Author"))])))

    #expect(batch.pts == 123)
    #expect(!batch.isFinal)
    #expect(!batch.skippedGap)
    #expect(batch.users.count == 1)
    #expect(batch.updates.count == 3)
    // The messages come first and in order, so the import sees the channel's
    // own order.
    guard case .updateNewChannelMessage(let first) = batch.updates[0],
      case .updateNewChannelMessage(let second) = batch.updates[1]
    else {
      Issue.record("new messages were not wrapped as updateNewChannelMessage")
      return
    }
    #expect(first.message == Self.post(1))
    #expect(second.message == Self.post(2))
    // The channel's position is the batch's, so a wrapped message carries none.
    #expect(first.pts == 0)
    #expect(first.ptsCount == 0)
    #expect(batch.updates[2] == deletion)
  }

  @Test("a too-long difference is a skipped gap, resuming at the dialog's pts")
  func decodesATooLongDifference() throws {
    let batch = ChannelDifferenceDecoder.decode(
      .channelDifferenceTooLong(
        TL.Updates.ChannelDifferenceTooLong(
          final: true, timeout: 60, dialog: Self.dialog(pts: 900),
          messages: [Self.post(8), Self.post(9)], chats: [],
          users: [.user(TL.User(id: 7, firstName: "Author"))])))

    #expect(batch.skippedGap)
    #expect(batch.pts == 900)
    #expect(batch.topMessageID == 9)
    #expect(batch.isFinal)
    #expect(batch.updates.count == 2)
    #expect(ChannelUpdateFilter.updates(batch.updates, forChannelID: Self.channelID).count == 2)
  }

  @Test("a too-long difference with no pts leaves the caller to ask for one")
  func decodesATooLongDifferenceWithoutAPTS() {
    let batch = ChannelDifferenceDecoder.decode(
      .channelDifferenceTooLong(
        TL.Updates.ChannelDifferenceTooLong(
          final: true, dialog: Self.dialog(pts: nil), messages: [], chats: [], users: [])))

    #expect(batch.skippedGap)
    #expect(batch.pts == nil)
    #expect(batch.topMessageID == 9)
  }

  @Test("a dialogFolder in place of a dialog is not a position either")
  func decodesATooLongDifferenceWithAFolder() {
    let batch = ChannelDifferenceDecoder.decode(
      .channelDifferenceTooLong(
        TL.Updates.ChannelDifferenceTooLong(
          final: true,
          dialog: .dialogFolder(
            TL.DialogFolder(
              folder: TL.Folder(id: 1, title: "Archive"),
              peer: .peerChannel(TL.PeerChannel(channelId: Self.channelID)), topMessage: 1,
              unreadMutedPeersCount: 0, unreadUnmutedPeersCount: 0,
              unreadMutedMessagesCount: 0, unreadUnmutedMessagesCount: 0)),
          messages: [], chats: [], users: [])))

    #expect(batch.pts == nil)
    #expect(batch.topMessageID == nil)
  }

  @Test("exact-id history is filtered and ordered oldest first")
  func decodesHistory() {
    let other = TL.MessageType.message(
      TL.Message(
        post: true, id: 2,
        peerId: .peerChannel(TL.PeerChannel(channelId: Self.channelID + 1)),
        date: 1_002, message: "other"))
    let page = ChannelHistoryDecoder.decode(
      .channelMessages(
        TL.Messages.ChannelMessages(
          pts: 50, count: 4,
          messages: [Self.post(3), .messageEmpty(TL.MessageEmpty(id: 2)), other, Self.post(1)],
          topics: [], chats: [], users: [])),
      forChannelID: Self.channelID)

    #expect(page.updates.count == 2)
    guard case .updateNewChannelMessage(let first) = page.updates[0],
      case .message(let firstMessage) = first.message,
      case .updateNewChannelMessage(let second) = page.updates[1],
      case .message(let secondMessage) = second.message
    else {
      Issue.record("history was not converted to channel updates")
      return
    }
    #expect(firstMessage.id == 1)
    #expect(secondMessage.id == 3)
  }

  @Test("every PERSISTENT_TIMESTAMP error means the stored position is unusable")
  func recognisesRejectedTimestamps() {
    for message in [
      "PERSISTENT_TIMESTAMP_EMPTY", "PERSISTENT_TIMESTAMP_INVALID",
      "PERSISTENT_TIMESTAMP_OUTDATED",
    ] {
      #expect(ChannelState.rejectsStoredPTS(MTProtoRPCError(code: 400, message: message)))
    }
    #expect(!ChannelState.rejectsStoredPTS(MTProtoRPCError(code: 400, message: "CHANNEL_INVALID")))
    #expect(!ChannelState.rejectsStoredPTS(TelegramClientError.unexpectedAccountKind))
  }
}
