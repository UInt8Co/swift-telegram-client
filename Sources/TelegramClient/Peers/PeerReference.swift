import TelegramSchema

/// What a channel peer *is*. A broadcast channel and a supergroup both keep
/// their own `pts` and answer `updates.getChannelDifference`, so either is read
/// the same way — but a broadcast post belongs to the channel while a supergroup
/// message belongs to whoever sent it.
public enum ChannelKind: String, Equatable, Sendable, CustomStringConvertible {
  case broadcast
  case supergroup

  public var description: String {
    switch self {
    case .broadcast: "channel"
    case .supergroup: "supergroup"
    }
  }
}

/// A channel this session can address: the id and the access hash that names it
/// to *this* account, together with what it turned out to be.
public struct ChannelReference: Equatable, Sendable {
  public var id: Int64
  public var accessHash: Int64
  public var title: String
  public var kind: ChannelKind
  /// Whether the peer keeps its messages in topics. Only a supergroup can.
  public var isForum: Bool

  public init(
    id: Int64, accessHash: Int64, title: String, kind: ChannelKind = .broadcast,
    isForum: Bool = false
  ) {
    self.id = id
    self.accessHash = accessHash
    self.title = title
    self.kind = kind
    self.isForum = isForum
  }

  public var inputPeer: TL.InputPeerType {
    .inputPeerChannel(TL.InputPeerChannel(channelId: id, accessHash: accessHash))
  }

  public var inputChannel: TL.InputChannelType {
    .inputChannel(TL.InputChannel(channelId: id, accessHash: accessHash))
  }
}

/// A user this session can address.
public struct UserReference: Equatable, Sendable {
  public var id: Int64
  public var accessHash: Int64

  public init(id: Int64, accessHash: Int64) {
    self.id = id
    self.accessHash = accessHash
  }

  public var inputPeer: TL.InputPeerType {
    .inputPeerUser(TL.InputPeerUser(userId: id, accessHash: accessHash))
  }

  public var inputUser: TL.InputUserType {
    .inputUser(TL.InputUser(userId: id, accessHash: accessHash))
  }
}

/// How a peer named only by its id is found.
///
/// An access hash is issued to one account for one peer, so an id alone is not
/// an address — the hash has to come from somewhere. There are two places it can
/// come from, and which one applies is a property of the account, not of the
/// peer.
public enum PeerLookup: Equatable, Sendable {
  /// Ask for the peer by id with a zero access hash. Bots may do this for a peer
  /// they are in, and have to: they cannot enumerate dialogs at all.
  /// <https://core.telegram.org/api/peers#access-hash>
  case byID
  /// Walk the account's dialog list until the peer appears. What a user account
  /// does, since a zero hash is refused for one.
  case inDialogs
}

/// How a peer is named in configuration or by a user: `@username`, a bare
/// MTProto id, or the `-100…` form the Bot API prints.
public enum PeerLocator: Equatable, Sendable, CustomStringConvertible {
  case id(Int64)
  case username(String)

  public init?(_ text: String) {
    if text.first == "@" {
      let username = String(text.dropFirst())
      guard !username.isEmpty, username.allSatisfy(Self.isUsernameCharacter) else {
        return nil
      }
      self = .username(username.lowercased())
    } else if let id = Int64(text), id > 0 {
      self = .id(id)
    } else if text.hasPrefix("-100"), let id = Int64(text.dropFirst(4)), id > 0 {
      self = .id(id)
    } else {
      return nil
    }
  }

  public var description: String {
    switch self {
    case .id(let id): String(id)
    case .username(let username): "@\(username)"
    }
  }

  private static func isUsernameCharacter(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber || character == "_")
  }
}
