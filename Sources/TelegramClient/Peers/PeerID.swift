import TelegramSchema

/// A numeric Telegram peer identity, without access hashes or resolution state.
///
/// Codable encodes `kind` as `user`, `chat` or `channel`, and `id` as an integer.
/// IDs in different kinds remain distinct; values are preserved without validation.
public struct PeerID: Hashable, Codable, Sendable, CustomStringConvertible {
  /// The namespace in which a numeric Telegram ID is interpreted.
  public enum Kind: String, Codable, Sendable {
    /// A user account.
    case user
    /// A basic group.
    case chat
    /// A channel or supergroup.
    case channel
  }
  /// The peer namespace.
  public var kind: Kind
  /// The numeric ID in that namespace; this is not a Bot API signed chat ID.
  public var id: Int64
  /// Creates an identity without validating or resolving its numeric ID.
  public init(kind: Kind, id: Int64) {
    self.kind = kind
    self.id = id
  }
  /// Projects a native Telegram peer into its kind and numeric ID.
  public init(_ peer: TL.PeerType) {
    switch peer {
    case .peerUser(let p): self.init(kind: .user, id: p.userId)
    case .peerChat(let p): self.init(kind: .chat, id: p.chatId)
    case .peerChannel(let p): self.init(kind: .channel, id: p.channelId)
    }
  }
  /// A stable `kind:id` representation, such as `user:1`.
  public var description: String { "\(kind.rawValue):\(id)" }
  /// The equivalent native Telegram peer, without an access hash.
  public var tl: TL.PeerType {
    switch kind {
    case .user: .peerUser(.init(userId: id))
    case .chat: .peerChat(.init(chatId: id))
    case .channel: .peerChannel(.init(channelId: id))
    }
  }
}

/// A message ID scoped to a Telegram peer.
///
/// Codable encodes `peer` as a ``PeerID`` object and `id` as an integer.
/// This value does not resolve peers or translate IDs across group migrations.
public struct MessageAddress: Hashable, Codable, Sendable {
  /// The dialog or channel containing the message.
  public var peer: PeerID
  /// The message ID within the peer.
  public var id: Int32
  /// Creates an address without validating the message ID.
  public init(peer: PeerID, id: Int32) {
    self.peer = peer
    self.id = id
  }
}
