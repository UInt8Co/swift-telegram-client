#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramSchema
import TelegramClient
import Testing

/// https://core.telegram.org/api/min: the context a `min` constructor was seen
/// in is passed as `inputUserFromMessage`, with `msg_id` set to that message
/// and `peer` to the chat it belongs to.
@Suite struct MessageContextPeerTests {
  @Test func aUserIsNamedByTheMessageItWasSeenIn() {
    let group = PeerID(kind: .channel, id: 100)
    let chat = TL.InputPeerType.inputPeerChannel(.init(channelId: 100, accessHash: 5))
    let user = PeerID(kind: .user, id: 7)
    let seen = MessageAddress(peer: group, id: 3)
    #expect(MessageContextPeer.inputUser(user, seenIn: seen, chat: chat)
      == .inputUserFromMessage(.init(peer: chat, msgId: 3, userId: 7)))
    // An ephemeral command or guest query carries no addressable message ID,
    // an unreachable chat cannot be context, and a channel is not a user.
    #expect(MessageContextPeer.inputUser(user, seenIn: .init(peer: group, id: 0), chat: chat) == nil)
    #expect(MessageContextPeer.inputUser(user, seenIn: seen, chat: nil) == nil)
    #expect(MessageContextPeer.inputUser(.init(kind: .channel, id: 7), seenIn: seen, chat: chat) == nil)
  }
  @Test func aChannelIsNamedByAMessageInAnotherChat() {
    let group = PeerID(kind: .channel, id: 100)
    let chat = TL.InputPeerType.inputPeerChannel(.init(channelId: 100, accessHash: 5))
    let origin = PeerID(kind: .channel, id: 200)
    let seen = MessageAddress(peer: group, id: 3)
    #expect(MessageContextPeer.inputChannel(origin, seenIn: seen, chat: chat)
      == .inputChannelFromMessage(.init(peer: chat, msgId: 3, channelId: 200)))
    #expect(MessageContextPeer.inputChannel(group, seenIn: seen, chat: chat) == nil)
    #expect(MessageContextPeer.inputChannel(origin, seenIn: .init(peer: group, id: 0), chat: chat) == nil)
    #expect(MessageContextPeer.inputChannel(.init(kind: .user, id: 200), seenIn: seen, chat: chat) == nil)
  }

}
