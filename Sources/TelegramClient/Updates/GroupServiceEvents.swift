import TelegramSchema

/// Pure inspection of received TL service messages and membership updates.
public enum GroupServiceEvents {
  /// Whether a non-private service message announces an addition, link, request or community join.
  public static func isJoin(_ message: TL.MessageType) -> Bool {
    guard case .messageService(let service) = message, PeerID(service.peerId).kind != .user else { return false }
    switch service.action {
    case .messageActionChatAddUser, .messageActionChatJoinedByLink, .messageActionChatJoinedByRequest,
      .messageActionChatJoinedViaCommunity: return true
    default: return false
    }
  }

  /// Identifies membership-related updates; callers should fetch current state rather than apply stale deltas.
  public static func membershipGroup(_ update: TL.UpdateType) -> PeerID? {
    switch update {
    case .updateChannelParticipant(let value): return .init(kind: .channel, id: value.channelId)
    case .updateChatParticipant(let value): return .init(kind: .chat, id: value.chatId)
    case .updateChatParticipantAdd(let value): return .init(kind: .chat, id: value.chatId)
    case .updateChatParticipantDelete(let value): return .init(kind: .chat, id: value.chatId)
    case .updateChatParticipantAdmin(let value): return .init(kind: .chat, id: value.chatId)
    case .updateChatParticipants(let value):
      switch value.participants {
      case .chatParticipants(let value): return .init(kind: .chat, id: value.chatId)
      case .chatParticipantsForbidden(let value): return .init(kind: .chat, id: value.chatId)
      }
    // Service messages also announce joins/leaves, including in recovered
    // history. Always fetch current membership rather than applying a delta
    // that could be duplicated or older than the latest Telegram state.
    case .updateNewMessage(let value): return membershipGroup(value.message)
    case .updateNewChannelMessage(let value): return membershipGroup(value.message)
    default: return nil
    }
  }

  /// Identifies add, delete, link and request service events. Community joins are not refresh signals.
  public static func membershipGroup(_ message: TL.MessageType) -> PeerID? {
    guard case .messageService(let value) = message else { return nil }
    switch value.action {
    case .messageActionChatAddUser, .messageActionChatDeleteUser,
      .messageActionChatJoinedByLink, .messageActionChatJoinedByRequest:
      return PeerID(value.peerId)
    default: return nil
    }
  }
}
