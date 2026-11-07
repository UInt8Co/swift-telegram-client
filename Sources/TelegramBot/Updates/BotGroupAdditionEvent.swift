import TelegramClient
import TelegramSchema

/// An attributed bot addition. Pure decoding neither performs I/O nor guarantees current membership.
public struct BotGroupAdditionEvent: Codable, Sendable, Equatable {
  /// The Telegram update namespace containing the replay identifier.
  public enum Source: String, Codable, Sendable {
    /// Channel participant transition; identifier is qts.
    case channelParticipant
    /// Basic-group participant addition; identifier is version.
    case chatParticipantAdd
    /// Basic-group participant transition; identifier is qts.
    case chatParticipant
    /// Basic-group service message; identifier is message ID.
    case serviceMessage
  }

  /// Group receiving the bot.
  public let group: PeerID
  /// Inviting or promoting user; never the bot itself.
  public let by: PeerID
  /// Telegram event date in Unix seconds.
  public let date: Int32
  /// Update form that supplied the event.
  public let source: Source
  /// Replay identifier in the source namespace (qts, version or message ID).
  public let sourceID: Int32

  /// Decodes additions with a positive, non-self actor; promotions and unrestrictions are excluded.
  /// Does not deduplicate different update forms or fetch current membership.
  public static func parse(_ update: TL.UpdateType, botID: Int64) -> Self? {
    switch update {
    case .updateChannelParticipant(let value):
      guard value.userId == botID, !member(value.prevParticipant), member(value.newParticipant),
         value.actorId != botID else { return nil }
      let fallback: Int64?
      switch value.newParticipant {
      case .channelParticipantSelf(let participant): fallback = participant.inviterId
      case .channelParticipantAdmin(let participant):
        fallback = participant.inviterId.flatMap { $0 > 0 && $0 != botID ? $0 : nil } ?? participant.promotedBy
      default: fallback = nil
      }
      return make(group: .init(kind: .channel, id: value.channelId),
            actor: value.actorId > 0 ? value.actorId : fallback, date: value.date,
            source: .channelParticipant, id: value.qts, botID: botID)
    case .updateChatParticipantAdd(let value) where value.userId == botID:
      return make(group: .init(kind: .chat, id: value.chatId), actor: value.inviterId,
            date: value.date, source: .chatParticipantAdd, id: value.version, botID: botID)
    case .updateChatParticipant(let value) where value.userId == botID:
      guard value.prevParticipant == nil, value.newParticipant != nil else { return nil }
      return make(group: .init(kind: .chat, id: value.chatId), actor: value.actorId,
            date: value.date, source: .chatParticipant, id: value.qts, botID: botID)
    case .updateNewMessage(let value): return parse(value.message, botID: botID)
    default: return nil
    }
  }

  /// Decodes basic-group add-user service messages, including recovered history.
  public static func parse(_ message: TL.MessageType, botID: Int64) -> Self? {
    guard case .messageService(let value) = message,
       case .peerChat(let group) = value.peerId,
       case .messageActionChatAddUser(let action) = value.action, action.users.contains(botID),
       case .peerUser(let actor) = value.fromId else { return nil }
    return make(group: .init(kind: .chat, id: group.chatId), actor: actor.userId,
          date: value.date, source: .serviceMessage, id: value.id, botID: botID)
  }

  private static func make(group: PeerID, actor: Int64?, date: Int32, source: Source, id: Int32, botID: Int64) -> Self? {
    guard let actor, actor > 0, actor != botID else { return nil }
    return .init(group: group, by: .init(kind: .user, id: actor), date: date, source: source, sourceID: id)
  }

  private static func member(_ participant: TL.ChannelParticipantType?) -> Bool {
    switch participant {
    case nil, .channelParticipantLeft: false
    case .channelParticipantBanned(let value): !value.left && !value.bannedRights.viewMessages
    default: true
    }
  }
}
