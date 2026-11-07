import TelegramClient
import TelegramSchema

/// Native requested-peer keyboards and response decoding. Selections are not authorization.
public enum RequestedPeerPicker {
  /// Creates a single-use, resizing keyboard containing one peer-request button.
  /// The caller supplies Telegram constraints and a positive maximum quantity (default one).
  /// Telegram enforces picker constraints; callers must recheck permissions when using a selection.
  public static func keyboard(
    text: String, buttonID: Int32, peerType: TL.RequestPeerTypeType, maxQuantity: Int32 = 1
  ) -> TL.ReplyMarkupType {
    precondition(maxQuantity > 0)
    return .replyKeyboardMarkup(.init(resize: true, singleUse: true, rows: [
      .init(buttons: [.init(text: text, type: .inputButtonTypeRequestPeer(.init(
        buttonId: buttonID, peerType: peerType, maxQuantity: maxQuantity)))])
    ]))
  }

  /// Returns selected peer identities in Telegram's order for the matching button.
  /// By default only private-chat service responses are accepted. Optional count and kind
  /// constraints reject the whole response on mismatch. This performs no access checks or I/O.
  public static func selectedPeers(
    in message: TL.MessageType, buttonID: Int32, privateChatOnly: Bool = true,
    count: ClosedRange<Int>? = nil, allowedKinds: Set<PeerID.Kind>? = nil
  ) -> [PeerID]? {
    guard case .messageService(let service) = message,
      !privateChatOnly || PeerID(service.peerId).kind == .user,
      case .messageActionRequestedPeerSentMe(let action) = service.action,
      action.buttonId == buttonID, count?.contains(action.peers.count) ?? true
    else { return nil }
    let peers: [PeerID] = action.peers.map {
      switch $0 {
      case .requestedPeerChat(let peer): .init(kind: .chat, id: peer.chatId)
      case .requestedPeerChannel(let peer): .init(kind: .channel, id: peer.channelId)
      case .requestedPeerUser(let peer): .init(kind: .user, id: peer.userId)
      }
    }
    guard allowedKinds.map({ kinds in peers.allSatisfy { kinds.contains($0.kind) } }) ?? true else { return nil }
    return peers
  }
}
