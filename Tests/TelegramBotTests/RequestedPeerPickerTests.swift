import TelegramBot
import TelegramClient
import TelegramSchema
import Testing

@Suite struct RequestedPeerPickerTests {
  @Test func keyboardPreservesCallerConstraints() throws {
    let constraints = TL.RequestPeerTypeType.requestPeerTypeChat(.init(botParticipant: true,
      userAdminRights: .init(other: true)))
    guard case .replyKeyboardMarkup(let keyboard) = RequestedPeerPicker.keyboard(
      text: "Choose", buttonID: 42, peerType: constraints, maxQuantity: 3),
      case .inputButtonTypeRequestPeer(let request) = keyboard.rows.first?.buttons.first?.type
    else { Issue.record("Expected a request keyboard"); return }
    #expect(keyboard.resize && keyboard.singleUse)
    #expect(keyboard.rows.first?.buttons.first?.text == "Choose")
    #expect(request.buttonId == 42 && request.maxQuantity == 3 && request.peerType == constraints)
  }

  private func response(button: Int32 = 42, peer: TL.PeerType = .peerUser(.init(userId: 7)),
    peers: [TL.RequestedPeerType]) -> TL.MessageType {
    .messageService(.init(id: 1, peerId: peer, date: 1,
      action: .messageActionRequestedPeerSentMe(.init(buttonId: button, peers: peers))))
  }

  @Test func identitiesPreserveOrderAndRejectMismatchedResponses() {
    let peers: [TL.RequestedPeerType] = [.requestedPeerChat(.init(chatId: 8)),
      .requestedPeerChannel(.init(channelId: 9)), .requestedPeerUser(.init(userId: 10))]
    let message = response(peers: peers)
    #expect(RequestedPeerPicker.selectedPeers(in: message, buttonID: 42) == [
      .init(kind: .chat, id: 8), .init(kind: .channel, id: 9), .init(kind: .user, id: 10)])
    #expect(RequestedPeerPicker.selectedPeers(in: message, buttonID: 41) == nil)
    #expect(RequestedPeerPicker.selectedPeers(in: message, buttonID: 42, count: 1...1) == nil)
    #expect(RequestedPeerPicker.selectedPeers(in: message, buttonID: 42, allowedKinds: [.chat, .channel]) == nil)
    #expect(RequestedPeerPicker.selectedPeers(in: response(peers: [peers[1]]), buttonID: 42,
      count: 1...1, allowedKinds: [.chat, .channel]) == [.init(kind: .channel, id: 9)])
    let groupResponse = response(peer: .peerChat(.init(chatId: 8)), peers: peers)
    #expect(RequestedPeerPicker.selectedPeers(in: groupResponse, buttonID: 42) == nil)
    #expect(RequestedPeerPicker.selectedPeers(in: groupResponse, buttonID: 42, privateChatOnly: false)?.count == 3)
    #expect(RequestedPeerPicker.selectedPeers(in: .message(.init(id: 1, peerId: .peerUser(.init(userId: 7)),
      date: 1, message: "hello")), buttonID: 42) == nil)
  }
}
