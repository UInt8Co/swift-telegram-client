#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import TelegramSchema
import TelegramClient

@Suite struct MessageRepliesTests {
  @Test func privateReplyReferencesTheSourceChatAndMessageWithoutAForumDestination() throws {
    let source = MessageAddress(peer: .init(kind: .channel, id: 600), id: 12)
    let sourcePeer = TL.InputPeerType.inputPeerChannel(.init(channelId: 600, accessHash: 123))
    let reply = MessageReplies.external(messageID: source.id, sourcePeer: sourcePeer)
    guard case .inputReplyToMessage(let message) = reply else {
      Issue.record("An external reply must reply to the ordinary source message")
      return
    }
    #expect(message.replyToMsgId == source.id)
    #expect(message.replyToPeerId == sourcePeer)
    #expect(message.topMsgId == nil)
    #expect(try TL.InputReplyToType(tlData: reply.tlSerialized()) == reply)
  }

  @Test func destinationTopicsAreExplicit() {
    let peer = TL.InputPeerType.inputPeerChannel(.init(channelId: 600, accessHash: 123))
    #expect(MessageReplies.external(messageID: 12, sourcePeer: peer, destinationTopicID: 42)
      == .inputReplyToMessage(.init(replyToMsgId: 12, topMsgId: 42, replyToPeerId: peer)))
    #expect(MessageReplies.message(12, topicID: 42) == .inputReplyToMessage(.init(replyToMsgId: 12, topMsgId: 42)))
    #expect(MessageReplies.topic(nil) == nil)
    #expect(MessageReplies.topic(1) == .inputReplyToMessage(.init(replyToMsgId: 1)))
  }
}
