import TelegramClient
import TelegramSchema
import Testing

@Suite("Update sequences")
struct UpdateSequenceTests {
  private static func channelMessage(_ channel: Int64, pts: Int32, count: Int32 = 1)
    -> TL.UpdateType
  {
    .updateNewChannelMessage(
      .init(
        message: .messageEmpty(.init(id: pts, peerId: .peerChannel(.init(channelId: channel)))),
        pts: pts, ptsCount: count))
  }

  private static func accountDeletion(pts: Int32, count: Int32 = 1) -> TL.UpdateType {
    .updateDeleteMessages(.init(messages: [1], pts: pts, ptsCount: count))
  }

  private static func positions(
    pts: Int32 = 10, qts: Int32 = 5, seq: Int32 = 3, channels: [Int64: Int32] = [7: 100]
  ) -> SequencePositions {
    .init(account: .init(pts: pts, qts: qts, date: 1, seq: seq), channels: channels)
  }

  @Test func classifiesUpdatesBySequence() {
    #expect(UpdateSequence.of(Self.channelMessage(7, pts: 101)) == .channel(7, pts: 101, count: 1))
    #expect(
      UpdateSequence.of(
        .updateDeleteChannelMessages(.init(channelId: 7, messages: [1], pts: 9, ptsCount: 1)))
        == .channel(7, pts: 9, count: 1))
    #expect(UpdateSequence.of(Self.accountDeletion(pts: 11)) == .account(pts: 11, count: 1))
    #expect(
      UpdateSequence.of(
        .updateBotChatInviteRequester(
          .init(
            peer: .peerChannel(.init(channelId: 7)), date: 1,
            userId: 2, about: "", invite: .chatInvitePublicJoinRequests(.init()), qts: 6)))
        == .qts(6))
    #expect(UpdateSequence.of(.updateChannelTooLong(.init(channelId: 7))) == .channelTooLong(7))
    #expect(
      UpdateSequence.of(.updateUserStatus(.init(userId: 1, status: .userStatusEmpty(.init()))))
        == nil)
  }

  @Test func continuousPushesAdvanceWithoutAGap() {
    var saved = Self.positions()
    let gaps = saved.advance(past: [
      .init(
        seq: .init(start: 4, end: 4, date: 50),
        updates: [.channel(7, pts: 101, count: 1), .account(pts: 11, count: 1), .qts(6)]),
      // Out of order within the pass, and one already applied.
      .init(updates: [
        .channel(7, pts: 103, count: 2), .channel(7, pts: 100, count: 1),
        .account(pts: 13, count: 2),
      ]),
    ])
    #expect(gaps.isEmpty)
    #expect(saved.account == .init(pts: 13, qts: 6, date: 50, seq: 4))
    #expect(saved.channels == [7: 103])
  }

  @Test func aGapKeepsItsSequenceWhereItWas() {
    var saved = Self.positions(channels: [7: 100, 8: 20])
    let gaps = saved.advance(past: [
      .init(updates: [
        .account(pts: 12, count: 1), .channel(7, pts: 102, count: 1),
        .channel(8, pts: 21, count: 1), .channel(9, pts: 5, count: 1),
      ])
    ])
    #expect(gaps == .init(account: true, channels: [7, 9]))
    #expect(saved.account == Self.positions().account)
    #expect(saved.channels == [7: 100, 8: 21])
  }

  @Test func qtsAndSeqGapsAskForTheAccountDifference() {
    var byQTS = Self.positions()
    #expect(byQTS.advance(past: [.init(updates: [.qts(7)])]) == .init(account: true))
    #expect(byQTS.account.qts == 5)
    var bySeq = Self.positions()
    #expect(
      bySeq.advance(past: [.init(seq: .init(start: 5, end: 5, date: 9))]) == .init(account: true))
    #expect(bySeq.account.seq == 3)
  }

  @Test func containersThatLoseUpdatesAskForEverything() {
    var saved = Self.positions()
    #expect(PushSequence(.updatesTooLong(.init())).complete == false)
    #expect(saved.advance(past: [.init(.updatesTooLong(.init()))]).account)
    #expect(
      saved.advance(past: [.init(updates: [.channelTooLong(7), .unfollowed])])
        == .init(account: true, channels: [7]))
    #expect(saved == Self.positions())
  }

  @Test func readsContainerOrder() {
    let combined = PushSequence(
      .updatesCombined(
        .init(
          updates: [Self.accountDeletion(pts: 11)], users: [], chats: [],
          date: 9, seqStart: 4, seq: 5)))
    #expect(
      combined
        == .init(seq: .init(start: 4, end: 5, date: 9), updates: [.account(pts: 11, count: 1)]))
    let unordered = PushSequence(
      .updates(.init(updates: [], users: [], chats: [], date: 9, seq: 0)))
    #expect(unordered.seq == nil && unordered.complete)
  }
}
