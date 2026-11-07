import TelegramClient
import TelegramSchema
import Testing

@Suite struct PeerSightingsTests {
  private let group = PeerID(kind: .channel, id: 100)
  @Test func reactiveUpdatesAlsoObservePeersWithoutConstructors() {
    #expect(PeerSightings.peers(in: .updateUserName(.init(userId: 42, firstName: "Name", lastName: "", usernames: [])))
      == [.init(kind: .user, id: 42)])
    #expect(PeerSightings.peers(in: .updateChannel(.init(channelId: 99))) == [.init(kind: .channel, id: 99)])
    #expect(PeerSightings.peers(in: .updatePeerBlocked(.init(blocked: true, peerId: .peerUser(.init(userId: 42)))))
      == [.init(kind: .user, id: 42)])
  }
  @Test func messagesNameTheirSenderForwardOriginMentionsAndServiceMembers() {
    let post = TL.UpdateType.updateNewChannelMessage(.init(message: .message(.init(id: 5,
      fromId: .peerUser(.init(userId: 7)), peerId: .peerChannel(.init(channelId: 100)),
      fwdFrom: .init(fromId: .peerChannel(.init(channelId: 200)), date: 1), date: 1, message: "hi @name",
      entities: [.messageEntityMentionName(.init(offset: 3, length: 5, userId: 8))])), pts: 1, ptsCount: 1))
    let join = TL.UpdateType.updateNewChannelMessage(.init(message: .messageService(.init(id: 6,
      fromId: .peerUser(.init(userId: 9)), peerId: .peerChannel(.init(channelId: 100)), date: 1,
      action: .messageActionChatAddUser(.init(users: [10, 11])))), pts: 2, ptsCount: 1))
    // A post sent as the group itself cannot name the group.
    let anonymous = TL.UpdateType.updateNewChannelMessage(.init(message: .message(.init(id: 7,
      fromId: .peerChannel(.init(channelId: 100)), peerId: .peerChannel(.init(channelId: 100)), date: 1,
      message: "")), pts: 3, ptsCount: 1))
    let sightings = PeerSightings.sightings(in: [post, join, anonymous, .updateUserStatus(.init(userId: 12, status: .userStatusEmpty(.init())))])
    let at = { MessageAddress(peer: group, id: $0) }
    #expect(sightings == [.init(kind: .user, id: 7): at(5), .init(kind: .channel, id: 200): at(5),
               .init(kind: .user, id: 8): at(5), .init(kind: .user, id: 9): at(6),
               .init(kind: .user, id: 10): at(6), .init(kind: .user, id: 11): at(6)])
    // An edit is the later sighting, so it names the sender.
    let edit = TL.UpdateType.updateEditChannelMessage(.init(message: .message(.init(id: 8,
      fromId: .peerUser(.init(userId: 7)), peerId: .peerChannel(.init(channelId: 100)), date: 1, message: "")),
      pts: 4, ptsCount: 1))
    #expect(PeerSightings.sightings(in: [post, edit])[.init(kind: .user, id: 7)] == at(8))
  }
  @Test func accessContextsRequireAnotherHistoryAndPositiveID() {
    let peer = PeerID(kind: .user, id: 7)
    #expect(PeerSightings.canResolve(peer, from: .init(peer: group, id: 1)))
    #expect(!PeerSightings.canResolve(peer, from: .init(peer: peer, id: 1)))
    #expect(!PeerSightings.canResolve(peer, from: .init(peer: group, id: 0)))
    #expect(!PeerSightings.canResolve(.init(kind: .chat, id: 7), from: .init(peer: group, id: 1)))
  }
}
