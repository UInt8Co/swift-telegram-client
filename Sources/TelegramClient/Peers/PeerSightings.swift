import TelegramSchema

/// Pure, partial peer observations; this does not enumerate every peer in every TL field.
/// Later updates replace earlier message contexts for the same peer.
public enum PeerSightings {
  /// Peers named by supported reactive updates, in field order, with one channel hint.
  public static func peers(in update: TL.UpdateType) -> [PeerID] {
    var peers: [PeerID] = []
    switch update {
    case .updateUserName(let value): peers.append(.init(kind: .user, id: value.userId))
    case .updateUserPhone(let value): peers.append(.init(kind: .user, id: value.userId))
    case .updateUserStatus(let value): peers.append(.init(kind: .user, id: value.userId))
    case .updateUserEmojiStatus(let value): peers.append(.init(kind: .user, id: value.userId))
    case .updateUser(let value): peers.append(.init(kind: .user, id: value.userId))
    case .updateChannel(let value): peers.append(.init(kind: .channel, id: value.channelId))
    case .updateChannelParticipant(let value):
      peers += [.init(kind: .channel, id: value.channelId), .init(kind: .user, id: value.userId)]
    case .updateChat(let value): peers.append(.init(kind: .chat, id: value.chatId))
    case .updateChatParticipant(let value):
      peers += [.init(kind: .chat, id: value.chatId), .init(kind: .user, id: value.userId)]
    case .updateChatParticipantAdd(let value):
      peers += [.init(kind: .chat, id: value.chatId), .init(kind: .user, id: value.userId)]
    case .updateChatParticipantDelete(let value):
      peers += [.init(kind: .chat, id: value.chatId), .init(kind: .user, id: value.userId)]
    case .updateChatParticipantAdmin(let value):
      peers += [.init(kind: .chat, id: value.chatId), .init(kind: .user, id: value.userId)]
    case .updateChatParticipants(let value):
      switch value.participants {
      case .chatParticipants(let participants):
        peers.append(.init(kind: .chat, id: participants.chatId))
      case .chatParticipantsForbidden(let participants):
        peers.append(.init(kind: .chat, id: participants.chatId))
      }
    case .updatePeerBlocked(let value): peers.append(PeerID(value.peerId))
    case .updatePeerSettings(let value): peers.append(PeerID(value.peer))
    case .updatePeerWallpaper(let value): peers.append(PeerID(value.peer))
    default: break
    }
    if let id = ChannelUpdateFilter.hintedChannelID(of: update),
      !peers.contains(.init(kind: .channel, id: id))
    {
      peers.append(.init(kind: .channel, id: id))
    }
    return peers
  }

  /// The message each peer in `updates` was seen in, where that message can
  /// name it in place of an access hash: its sender, its forward origin, the
  /// users it mentions by name and the members its service action names.
  /// https://core.telegram.org/api/min and https://core.telegram.org/api/peers
  public static func sightings(in updates: [TL.UpdateType]) -> [PeerID: MessageAddress] {
    var sightings: [PeerID: MessageAddress] = [:]
    for update in updates {
      let message: TL.MessageType
      switch update {
      case .updateNewMessage(let value): message = value.message
      case .updateEditMessage(let value): message = value.message
      case .updateNewChannelMessage(let value): message = value.message
      case .updateEditChannelMessage(let value): message = value.message
      default: continue
      }
      let address: MessageAddress
      var peers: [PeerID] = []
      switch message {
      case .message(let value):
        address = .init(peer: PeerID(value.peerId), id: value.id)
        peers += [value.fromId, value.fwdFrom?.fromId].compactMap { $0.map(PeerID.init) }
        for entity in value.entities ?? [] {
          if case .messageEntityMentionName(let mention) = entity {
            peers.append(.init(kind: .user, id: mention.userId))
          }
        }
      case .messageService(let value):
        address = .init(peer: PeerID(value.peerId), id: value.id)
        peers += [value.fromId].compactMap { $0.map(PeerID.init) }
        let users: [Int64]
        switch value.action {
        case .messageActionChatCreate(let action): users = action.users
        case .messageActionChatAddUser(let action): users = action.users
        case .messageActionChatDeleteUser(let action): users = [action.userId]
        case .messageActionChatJoinedByLink(let action): users = [action.inviterId]
        default: users = []
        }
        peers += users.map { .init(kind: .user, id: $0) }
      case .messageEmpty: continue
      }
      // A later update, such as an edit, is the likelier to still exist.
      for peer in peers where canResolve(peer, from: address) { sightings[peer] = address }
    }
    return sightings
  }

  /// Whether a positive message in another peer can supply a user/channel access context.
  public static func canResolve(_ peer: PeerID, from context: MessageAddress) -> Bool {
    peer.kind != .chat && context.id > 0 && context.peer != peer
  }
}
