import TelegramClient
import TelegramSchema
import Testing

@Suite struct ReplyResolverTests {
  private let group = PeerID(kind: .channel, id: 100)
  private func message(_ text: String, reply: TL.MessageReplyHeader? = nil) -> TL.Message {
    .init(id: 1, peerId: group.tl, replyTo: reply.map { .messageReplyHeader($0) }, date: 1, message: text)
  }
  @Test func topicResolverUsesForumRootAndIgnoresExternalReplies() {
    let direct = message("Hello", reply: .init(forumTopic: true, replyToMsgId: 50))
    #expect(ReplyResolver.topicID(for: direct) == 50)
    let nested = message("Hello", reply: .init(forumTopic: true, replyToMsgId: 70, replyToTopId: 50))
    #expect(ReplyResolver.topicID(for: nested) == 50)
    let explicitPeer = message("Hello", reply: .init(forumTopic: true, replyToMsgId: 50, replyToPeerId: group.tl))
    #expect(ReplyResolver.topicID(for: explicitPeer) == 50)
    let external = message("Hello", reply: .init(forumTopic: true, replyToMsgId: 50, replyToPeerId: PeerID(kind: .channel, id: 600).tl))
    #expect(ReplyResolver.topicID(for: external) == nil)
    let externalWithTopic = message("Hello", reply: .init(forumTopic: true, replyToMsgId: 50, replyToPeerId: PeerID(kind: .channel, id: 600).tl, replyToTopId: 70))
    #expect(ReplyResolver.topicID(for: externalWithTopic) == 70)
    let plainReply = message("Hello", reply: .init(replyToMsgId: 50))
    #expect(ReplyResolver.topicID(for: plainReply) == nil)
    let scheduled = message("Hello", reply: .init(replyToScheduled: true, forumTopic: true, replyToMsgId: 50))
    #expect(ReplyResolver.topicID(for: scheduled) == nil)
    let invalid = message("Hello", reply: .init(forumTopic: true, replyToMsgId: 0))
    #expect(ReplyResolver.topicID(for: invalid) == nil)
    #expect(ReplyResolver.topicID(for: message("Hello")) == nil)
  }
  @Test func policiesExplicitlyPreserveRawHeaders() {
    for header in [TL.MessageReplyHeader(replyToScheduled: true, forumTopic: true, replyToMsgId: 50),
                   .init(forumTopic: true, replyToMsgId: 50, replyToPeerId: .peerChannel(.init(channelId: 600)))] {
      let value = message("Hello", reply: header)
      #expect(ForumTopics.topicID(of: .message(value)) == 50)
      #expect(ReplyResolver.topicID(for: value) == nil)
    }
    #expect(ForumTopics.topicID(of: .message(message("", reply: .init(forumTopic: true, replyToMsgId: 0)))) == 0)
  }

  @Test func externalAddressesAndQuotedAuthorsAreExplicit() {
    let other = PeerID(kind: .channel, id: 600)
    let value = message("Hello", reply: .init(replyToMsgId: 50, replyToPeerId: other.tl,
      replyFrom: .init(fromId: .peerUser(.init(userId: 8)), date: 1)))
    #expect(ReplyResolver.address(for: value) == .init(peer: other, id: 50))
    #expect(ReplyResolver.quotedAuthor(for: value) == .init(kind: .user, id: 8))
    #expect(ReplyResolver.quotedAuthor(for: message("", reply: .init(replyFrom: .init(fromName: "Name", date: 1)))) == nil)
    #expect(ReplyResolver.address(for: message("", reply: .init(replyToScheduled: true, replyToMsgId: 50))) == nil)
    #expect(ReplyResolver.address(for: message("", reply: .init(replyToMsgId: 0))) == nil)
  }
}
