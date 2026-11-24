import MTProtoClientKit
import TelegramClient
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A user account's connection to this bot through chat automation (Telegram
/// Business connected bots). Pure data: holding one grants nothing until
/// Telegram accepts a call made through it.
public struct BusinessConnection: Codable, Sendable, Equatable {
  /// What the connected account lets the bot do in the chats it shares.
  /// Bit positions match `businessBotRights` flags.
  public struct Rights: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Send and edit messages in chats with a recent incoming message.
    public static let reply = Self(rawValue: 1 << 0)
    /// Mark incoming messages as read.
    public static let readMessages = Self(rawValue: 1 << 1)
    /// Delete messages the bot sent on the account's behalf.
    public static let deleteSentMessages = Self(rawValue: 1 << 2)
    /// Delete messages the account received, for both sides.
    public static let deleteReceivedMessages = Self(rawValue: 1 << 3)
    public static let editName = Self(rawValue: 1 << 4)
    public static let editBio = Self(rawValue: 1 << 5)
    public static let editProfilePhoto = Self(rawValue: 1 << 6)
    public static let editUsername = Self(rawValue: 1 << 7)
    public static let viewGifts = Self(rawValue: 1 << 8)
    public static let sellGifts = Self(rawValue: 1 << 9)
    public static let changeGiftSettings = Self(rawValue: 1 << 10)
    public static let transferAndUpgradeGifts = Self(rawValue: 1 << 11)
    public static let transferStars = Self(rawValue: 1 << 12)
    public static let manageStories = Self(rawValue: 1 << 13)

    /// Projects native rights field by field; absent rights are empty.
    public init(_ rights: TL.BusinessBotRights?) {
      guard let rights else {
        self = []
        return
      }
      let fields: [(Bool, Self)] = [
        (rights.reply, .reply), (rights.readMessages, .readMessages),
        (rights.deleteSentMessages, .deleteSentMessages),
        (rights.deleteReceivedMessages, .deleteReceivedMessages),
        (rights.editName, .editName), (rights.editBio, .editBio),
        (rights.editProfilePhoto, .editProfilePhoto), (rights.editUsername, .editUsername),
        (rights.viewGifts, .viewGifts), (rights.sellGifts, .sellGifts),
        (rights.changeGiftSettings, .changeGiftSettings),
        (rights.transferAndUpgradeGifts, .transferAndUpgradeGifts),
        (rights.transferStars, .transferStars), (rights.manageStories, .manageStories),
      ]
      self = fields.reduce(into: []) { if $1.0 { $0.insert($1.1) } }
    }
  }

  /// Opaque identifier for calls through this connection. Telegram issues a
  /// new one whenever the account changes the connection's settings.
  public let id: String
  /// The connected account.
  public let user: PeerID
  /// The datacenter that serves calls through this connection.
  public let dcID: Int32
  /// When the connection was made or last changed, in Unix seconds.
  public let date: Int32
  /// False once the account disconnected the bot or Telegram disabled the connection.
  public let isEnabled: Bool
  public let rights: Rights

  public init(id: String, user: PeerID, dcID: Int32, date: Int32, isEnabled: Bool, rights: Rights) {
    self.id = id
    self.user = user
    self.dcID = dcID
    self.date = date
    self.isEnabled = isEnabled
    self.rights = rights
  }

  public init(_ connection: TL.BotBusinessConnection) {
    self.init(
      id: connection.connectionId, user: .init(kind: .user, id: connection.userId),
      dcID: connection.dcId, date: connection.date, isEnabled: !connection.disabled,
      rights: .init(connection.rights))
  }
}

/// A message seen through a business connection, in a private chat of the
/// connected account. Pure data; it is not a message in any chat of the bot.
public struct BusinessMessage: Sendable {
  public let connectionID: String
  public let message: TL.MessageType
  /// The message this one replies to, when Telegram attached it.
  public let replyTo: TL.MessageType?

  public init(connectionID: String, message: TL.MessageType, replyTo: TL.MessageType?) {
    self.connectionID = connectionID
    self.message = message
    self.replyTo = replyTo
  }

  /// The connected account's private chat partner (the message's peer).
  public var chat: PeerID? {
    switch message {
    case .message(let value): PeerID(value.peerId)
    case .messageService(let value): PeerID(value.peerId)
    case .messageEmpty(let value): value.peerId.map(PeerID.init)
    }
  }

  /// The message ID in the connected account's own message sequence.
  public var id: Int32 {
    switch message {
    case .message(let value): value.id
    case .messageService(let value): value.id
    case .messageEmpty(let value): value.id
    }
  }

  /// Whether the connected account sent it, itself or through a bot.
  public var isOutgoing: Bool {
    switch message {
    case .message(let value): value.out
    case .messageService(let value): value.out
    case .messageEmpty: false
    }
  }

  /// Who wrote it: the named sender, or else the chat partner of an incoming
  /// message. Nil for outgoing messages without a named sender and for empty ones.
  public var sender: PeerID? {
    let from: TL.PeerType?
    switch message {
    case .message(let value): from = value.fromId
    case .messageService(let value): from = value.fromId
    case .messageEmpty: return nil
    }
    if let from { return PeerID(from) }
    return isOutgoing ? nil : chat
  }
}

/// A business-connection update decoded without I/O. Replay order and
/// deduplication stay with the caller's update sequence (these updates carry qts).
public enum BusinessUpdate: Sendable {
  /// A connection was made, changed, disabled or removed.
  case connection(BusinessConnection)
  case newMessage(BusinessMessage)
  case editedMessage(BusinessMessage)
  /// Messages were deleted from one of the connected account's private chats.
  case deletedMessages(connectionID: String, chat: PeerID, ids: [Int32])

  public init?(_ update: TL.UpdateType) {
    switch update {
    case .updateBotBusinessConnect(let value): self = .connection(.init(value.connection))
    case .updateBotNewBusinessMessage(let value):
      self = .newMessage(
        .init(connectionID: value.connectionId, message: value.message, replyTo: value.replyToMessage))
    case .updateBotEditBusinessMessage(let value):
      self = .editedMessage(
        .init(connectionID: value.connectionId, message: value.message, replyTo: value.replyToMessage))
    case .updateBotDeleteBusinessMessage(let value):
      self = .deletedMessages(connectionID: value.connectionId, chat: PeerID(value.peer), ids: value.messages)
    default: return nil
    }
  }

  /// The connection this update belongs to.
  public var connectionID: String {
    switch self {
    case .connection(let connection): connection.id
    case .newMessage(let message), .editedMessage(let message): message.connectionID
    case .deletedMessages(let id, _, _): id
    }
  }
}

/// Telegram refused a call made through a business connection.
public enum BusinessConnectionFailure: String, Error, Equatable, Sendable, CaseIterable,
  CustomStringConvertible
{
  /// The connection ID is unknown or stale: the account changed or removed the
  /// connection, and any newer one arrives as its own connection update.
  case connectionInvalid = "BUSINESS_CONNECTION_INVALID"
  /// The bot has no business mode in @BotFather, or the method cannot run
  /// through a connection.
  case notAllowed = "BUSINESS_CONNECTION_NOT_ALLOWED"
  /// The connection's rights do not cover the call.
  case accessForbidden = "BOT_ACCESS_FORBIDDEN"

  /// Recognizes this fact itself or an RPC error with a matching message, regardless of code.
  public init?(_ error: any Error) {
    if let fact = error as? Self { self = fact }
    else if let rpc = error as? MTProtoRPCError { self.init(errorMessage: rpc.message) }
    else { return nil }
  }

  /// Recognizes an exact RPC message.
  public init?(errorMessage: String) { self.init(rawValue: errorMessage) }

  /// The exact RPC message, suitable for logs.
  public var description: String { rawValue }
}

/// Calls made on behalf of a connected account. Transport only: callers own
/// gating, pacing, persistence and retries; errors and cancellation propagate.
public struct BusinessConnectionClient: Sendable {
  /// The API of a datacenter; a ``TelegramClientPool`` connection's `api`, for example.
  public typealias DatacenterAPI = @Sendable (Int32) async throws -> TLClient

  private let api: TLClient
  private let datacenter: DatacenterAPI

  /// `api` serves connection lookups; `datacenter` serves calls through a
  /// connection, on the datacenter Telegram assigned to it.
  public init(api: TLClient, datacenter: @escaping DatacenterAPI) {
    self.api = api
    self.datacenter = datacenter
  }

  /// Fetches a connection the bot has not seen, for example after losing
  /// updates. Nil when Telegram's answer does not describe that connection.
  public func connection(id: String) async throws -> BusinessConnection? {
    let updates = try await api.account.getBotBusinessConnection(connectionId: id)
    let list: [TL.UpdateType]
    switch updates {
    case .updates(let value): list = value.updates
    case .updatesCombined(let value): list = value.updates
    case .updateShort(let value): list = [value.update]
    default: list = []
    }
    for update in list {
      if case .connection(let connection)? = BusinessUpdate(update), connection.id == id {
        return connection
      }
    }
    return nil
  }

  /// Deletes messages for both sides in the connected account's private
  /// chats. Needs ``BusinessConnection/Rights/deleteReceivedMessages`` for
  /// messages the account received. The answer's pts belongs to the connected
  /// account, never to the bot's own update state, so it is not returned.
  public func deleteMessages(_ ids: [Int32], via connection: BusinessConnection) async throws {
    guard !ids.isEmpty else { return }
    let api = try await datacenter(connection.dcID)
    _ = try await api.invokeWithBusinessConnection(
      connectionId: connection.id, query: TL.Messages.DeleteMessages(revoke: true, id: ids))
  }
}
