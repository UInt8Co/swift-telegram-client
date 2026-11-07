import TelegramSchema

/// Constructs contextual peer references without fetching or validating access.
public enum MessageContextPeer {
  /// Names a user through a positive message ID and an available enclosing input peer.
  /// Returns nil for other peer kinds, nonpositive IDs or missing chat access. The caller
  /// must supply a real history message and its matching chat, never an ephemeral query.
  public static func inputUser(_ user: PeerID, seenIn message: MessageAddress,
    chat: TL.InputPeerType?) -> TL.InputUserType? {
    guard user.kind == .user, message.id > 0, let chat else { return nil }
    return .inputUserFromMessage(.init(peer: chat, msgId: message.id, userId: user.id))
  }

  /// Names a channel through a positive message in a different peer's history. Returns
  /// nil for the channel's own history, other kinds, nonpositive IDs or missing access.
  /// The caller must supply a real history message and its matching enclosing input peer.
  public static func inputChannel(_ channel: PeerID, seenIn message: MessageAddress,
    chat: TL.InputPeerType?) -> TL.InputChannelType? {
    guard channel.kind == .channel, message.id > 0, message.peer != channel, let chat else { return nil }
    return .inputChannelFromMessage(.init(peer: chat, msgId: message.id, channelId: channel.id))
  }
}
