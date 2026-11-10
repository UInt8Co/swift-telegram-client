import MTProtoClientKit
import TelegramClient
import TelegramSchema
import Testing

@Suite struct ForumTopicsTests {
  @Test(arguments: ForumTopicGone.allCases, [400, 403, 500])
  func goneTopicsRoundTrip(fact: ForumTopicGone, code: Int32) {
    #expect(ForumTopicGone(MTProtoRPCError(code: code, message: fact.rawValue)) == fact)
    #expect(ForumTopicGone(fact as any Error) == fact)
    #expect(ForumTopicGone(errorMessage: fact.rawValue) == fact)
    #expect(String(describing: fact) == fact.rawValue)
  }

  @Test func goneTopicsRejectNonmembers() {
    #expect(ForumTopicGone(errorMessage: "UNKNOWN") == nil)
    #expect(ForumTopicGone(MTProtoRPCError(code: 400, message: "UNKNOWN")) == nil)
    #expect(ForumTopicGone(CancellationError()) == nil)
  }

  @Test func titlesCollapseWhitespaceAndAlwaysHaveANonemptyFallback() {
    #expect(ForumTopics.title("  Hello\n\t world\u{00a0} ") == "Hello world")
    #expect(ForumTopics.title("Group\u{0}Name\u{7}\u{1b}") == "Group Name")
    #expect(ForumTopics.title("\u{0}\u{7f}") == "Topic")
    #expect(ForumTopics.title("") == "Topic")
    #expect(ForumTopics.title(" \n", fallback: " Custom\t title ") == "Custom title")
    #expect(ForumTopics.title("", fallback: " \n\t") == "Topic")
    #expect(ForumTopics.title("", fallback: String(repeating: "a", count: 129)).utf8.count == 128)
  }

  @Test func titlesCutAtCharacterBoundariesWithinUTF8Limit() {
    let limit = ForumTopics.maxTitleLength
    #expect(
      ForumTopics.title(String(repeating: "a", count: limit))
        == String(repeating: "a", count: limit))
    #expect(
      ForumTopics.title(String(repeating: "a", count: limit + 1)) == String(
        repeating: "a", count: 125) + "…")
    #expect(
      ForumTopics.title(String(repeating: "a", count: 124) + "😀x") == String(
        repeating: "a", count: 124) + "…")
    #expect(
      ForumTopics.title(String(repeating: "a", count: 120) + "😀xyzab") == String(
        repeating: "a", count: 120) + "😀x…")
    #expect(
      ForumTopics.title(String(repeating: "😀", count: 33)) == String(repeating: "😀", count: 31)
        + "…")
    #expect(
      ForumTopics.title(String(repeating: "a", count: 125) + "e\u{301}x") == String(
        repeating: "a", count: 125) + "…")
    // 50 CJK characters are 150 UTF-8 bytes but only 50 UTF-16 units.
    #expect(
      ForumTopics.title(String(repeating: "中", count: 50)) == String(repeating: "中", count: 41)
        + "…")
    let family = "👨‍👩‍👧‍👦"
    let result = ForumTopics.title(String(repeating: family, count: 20))
    #expect(result.utf8.count <= limit)
    #expect(result.dropLast().allSatisfy { String($0) == family })
  }

  @Test func topicIDsComeFromTopicServicesOrForumReplyHeaders() {
    let created = TL.MessageType.messageService(
      .init(
        id: 10, peerId: .peerChannel(.init(channelId: 7)),
        date: 1, action: .messageActionTopicCreate(.init(title: "Topic", iconColor: 0x6FB9F0))))
    #expect(ForumTopics.topicID(of: created) == 10)
    let peer = TL.PeerType.peerUser(.init(userId: 7))
    for (header, expected): (TL.MessageReplyHeaderType?, Int32?) in [
      (nil, nil),
      (.messageReplyHeader(.init(forumTopic: true, replyToMsgId: 10)), 10),
      (.messageReplyHeader(.init(forumTopic: true, replyToMsgId: 20, replyToTopId: 10)), 10),
      (.messageReplyHeader(.init(replyToMsgId: 20, replyToTopId: 10)), nil),
      (.messageReplyHeader(.init(forumTopic: true)), nil),
      (.messageReplyStoryHeader(.init(peer: peer, storyId: 10)), nil),
    ] {
      #expect(
        ForumTopics.topicID(
          of: .message(.init(id: 30, peerId: peer, replyTo: header, date: 1, message: "Hi")))
          == expected)
      #expect(
        ForumTopics.topicID(
          of: .messageService(
            .init(
              id: 30, peerId: peer, replyTo: header,
              date: 1, action: .messageActionPinMessage(.init())))) == expected)
    }
    #expect(ForumTopics.topicID(of: .messageEmpty(.init(id: 10))) == nil)
    #expect(
      ForumTopics.replyTo(topic: 10) == .inputReplyToMessage(.init(replyToMsgId: 10, topMsgId: 10)))
    #expect(
      ForumTopics.replyTo(topic: 10, message: 20)
        == .inputReplyToMessage(.init(replyToMsgId: 20, topMsgId: 10)))
  }

  @Test func colorsAreStableForPositiveNegativeAndExtremeKeys() {
    #expect(ForumTopics.iconColors == [0x6FB9F0, 0xFFD67E, 0xCB86DB, 0x8EEE98, 0xFF93B2, 0xFB6F5F])
    let fixtures: [(Int64, Int32)] = [
      (0, 0x6FB9F0), (1, 0xFFD67E), (5, 0xFB6F5F), (6, 0x6FB9F0),
      (-1, 0x8EEE98), (.min, 0xCB86DB), (.max, 0xFFD67E),
    ]
    for (key, color) in fixtures {
      #expect(ForumTopics.iconColor(for: key) == color)
      #expect(ForumTopics.iconColor(for: key) == ForumTopics.iconColor(for: key))
    }
  }
}
