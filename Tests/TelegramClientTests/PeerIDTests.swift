import TelegramClient
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct PeerIDTests {
  @Test func codableGoldenJSONPreservesPeerAndMessageShape() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let peerJSON = Data(#"{"id":1,"kind":"user"}"#.utf8)
    let messageJSON = Data(#"{"id":5,"peer":{"id":1,"kind":"user"}}"#.utf8)
    let peer = PeerID(kind: .user, id: 1)
    let message = MessageAddress(peer: peer, id: 5)
    #expect(try encoder.encode(peer) == peerJSON)
    #expect(try encoder.encode(message) == messageJSON)
    #expect(try JSONDecoder().decode(PeerID.self, from: peerJSON) == peer)
    #expect(try JSONDecoder().decode(MessageAddress.self, from: messageJSON) == message)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PeerID.self, from: Data(#"{"kind":"unknown","id":1}"#.utf8))
    }
  }

  @Test func nativePeersRoundTripWithoutChangingIDs() throws {
    for id: Int64 in [1, 42, .max, .min, 0] {
      for (kind, native): (PeerID.Kind, TL.PeerType) in [
        (.user, .peerUser(.init(userId: id))),
        (.chat, .peerChat(.init(chatId: id))),
        (.channel, .peerChannel(.init(channelId: id))),
      ] {
        let peer = PeerID(kind: kind, id: id)
        #expect(PeerID(native) == peer)
        #expect(peer.tl == native)
        #expect(PeerID(peer.tl) == peer)
        #expect(peer.description == "\(kind.rawValue):\(id)")
        #expect(try JSONDecoder().decode(PeerID.self, from: JSONEncoder().encode(peer)) == peer)
      }
    }
  }

  @Test func namespacesAndMessageIDsRemainDistinct() {
    let peers: Set<PeerID> = [
      .init(kind: .user, id: 1), .init(kind: .chat, id: 1), .init(kind: .channel, id: 1),
    ]
    #expect(peers.count == 3)
    var messages = Set(peers.map { MessageAddress(peer: $0, id: 5) })
    messages.insert(.init(peer: .init(kind: .user, id: 1), id: 6))
    #expect(messages.count == 4)
  }
}
