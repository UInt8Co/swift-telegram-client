import TelegramSchema

/// Telegram's two service actions and a refreshed basic chat describe the same
/// identity transition. Message IDs are deliberately not part of this mapping.
public struct GroupMigration: Sendable, Equatable, Hashable {
  /// The original basic-group ID.
  public let chatID: Int64
  /// The destination supergroup ID.
  public let channelID: Int64

  /// Creates a transition if both IDs are positive.
  public init?(chatID: Int64, channelID: Int64) {
    guard chatID > 0, channelID > 0 else { return nil }
    self.chatID = chatID
    self.channelID = channelID
  }

  /// Reads either migration service action, rejecting mismatched peer kinds.
  public init?(message: TL.MessageType) {
    guard case .messageService(let service) = message else { return nil }
    switch (service.peerId, service.action) {
    case (.peerChat(let peer), .messageActionChatMigrateTo(let action)):
      self.init(chatID: peer.chatId, channelID: action.channelId)
    case (.peerChannel(let peer), .messageActionChannelMigrateFrom(let action)):
      self.init(chatID: action.chatId, channelID: peer.channelId)
    default: return nil
    }
  }

  /// Reads the migration destination from basic-group metadata.
  public init?(chat: TL.ChatType) {
    guard case .chat(let chat) = chat, let destination = chat.migratedTo else { return nil }
    switch destination {
    case .inputChannel(let channel): self.init(chatID: chat.id, channelID: channel.channelId)
    case .inputChannelFromMessage(let channel):
      self.init(chatID: chat.id, channelID: channel.channelId)
    case .inputChannelEmpty: return nil
    }
  }

  /// `updateChat` only contains an ID; supply its refreshed peer from the
  /// enclosing updates container or a lookup. Never accept an unrelated peer.
  public init?(update: TL.UpdateType, refreshedChat: TL.ChatType? = nil) {
    switch update {
    case .updateNewMessage(let value): self.init(message: value.message)
    case .updateEditMessage(let value): self.init(message: value.message)
    case .updateNewChannelMessage(let value): self.init(message: value.message)
    case .updateEditChannelMessage(let value): self.init(message: value.message)
    case .updateChat(let value):
      guard let refreshedChat, let migration = Self(chat: refreshedChat),
        migration.chatID == value.chatId
      else { return nil }
      self = migration
    default: return nil
    }
  }
}
