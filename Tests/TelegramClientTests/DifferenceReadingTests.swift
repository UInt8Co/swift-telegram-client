import TelegramSchema
import Testing

@testable import TelegramClient

@Suite struct DifferenceReadingTests {
  private static let source: Int64 = 42

  private static func post(_ id: Int32, in channelID: Int64) -> TL.MessageType {
    .message(
      TL.Message(
        post: true, id: id, peerId: .peerChannel(TL.PeerChannel(channelId: channelID)),
        date: 100, message: "hello"))
  }

  @Test("a reading separates the source's updates from everything else in the difference")
  func readsSourceUpdatesAndOtherChannels() {
    let batch = DifferenceBatch(
      updates: [
        .updateNewChannelMessage(
          TL.UpdateNewChannelMessage(message: Self.post(1, in: Self.source), pts: 1, ptsCount: 1)),
        .updateDeleteChannelMessages(
          TL.UpdateDeleteChannelMessages(
            channelId: Self.source, messages: [1], pts: 2, ptsCount: 1)),
        .updateNewChannelMessage(
          TL.UpdateNewChannelMessage(message: Self.post(2, in: 77), pts: 3, ptsCount: 1)),
        .updateChannelTooLong(TL.UpdateChannelTooLong(channelId: 99)),
      ],
      users: [], chats: [], cursor: .beginning, hasMore: true)

    let reading = ChannelUpdateFilter.reading(
      batch.updates, forChannelID: Self.source, hasMore: batch.hasMore)
    #expect(reading.updates == 4)
    #expect(reading.forSource == 2)
    #expect(!reading.channelTooLong)
    #expect(reading.otherChannels == [77, 99])
    #expect(reading.hasMore)
    #expect(!reading.isQuiet)
    #expect(
      reading.kinds == [
        "updateNewChannelMessage": 2, "updateDeleteChannelMessages": 1,
        "updateChannelTooLong": 1,
      ])
  }

  @Test("updateChannelTooLong for the source is called out, not counted as another channel")
  func flagsAChannelDifferenceRequestForTheSource() {
    let batch = DifferenceBatch(
      updates: [.updateChannelTooLong(TL.UpdateChannelTooLong(channelId: Self.source))],
      users: [], chats: [], cursor: .beginning, hasMore: false)

    let reading = ChannelUpdateFilter.reading(
      batch.updates, forChannelID: Self.source, hasMore: batch.hasMore)
    #expect(reading.channelTooLong)
    #expect(reading.otherChannels.isEmpty)
    #expect(reading.forSource == 0)
    #expect(reading.description.contains("the source needs a channel difference"))
  }

  @Test("an empty difference with nothing left to page is quiet")
  func anEmptyDifferenceIsQuiet() {
    let reading = ChannelUpdateFilter.reading(
      [], forChannelID: Self.source, hasMore: false)
    #expect(reading.isQuiet)
    #expect(reading.description == "0 update(s); 0 for the source")
  }

  @Test("a reading reads back as one line")
  func describesItselfForTheLog() {
    let reading = DifferenceReading(
      updates: 3, forSource: 1, otherChannels: [8], kinds: ["updateNewChannelMessage": 3],
      hasMore: true)
    #expect(
      reading.description
        == "3 update(s); 1 for the source; other channel(s) 8; "
          + "updateNewChannelMessage x3; more to page")
  }
}
