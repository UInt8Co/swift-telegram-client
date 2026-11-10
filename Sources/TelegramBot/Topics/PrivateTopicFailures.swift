import MTProtoClientKit

/// Telegram refused topic creation in a bot's private chat with a user.
public enum PrivateTopicCreationRefusal: String, Error, Equatable, Sendable, CaseIterable,
  CustomStringConvertible
{
  /// Telegram refuses topic creation in this private chat. The @BotFather
  /// topic setting is one possible cause; the same bot may still open topics
  /// for other users.
  case forbidden = "BOT_FORUM_CREATE_FORBIDDEN"

  /// Telegram refuses a bot's topic creation in a private chat. Observed during
  /// 2026-11 for different bots and users at every layer tried while other requests succeeded.
  /// A refused request may still leave a topic-creation service message in
  /// the chat, pointing at a topic that some clients show and that
  /// `messages.deleteTopicHistory` rejects with `TOPIC_ID_INVALID`. Retrying
  /// with the same random ID was refused again without leaving another one,
  /// while a new random ID left another.
  case wrongHome = "BOT_TOPIC_WRONG_HOME"

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

/// RPC error messages meaning the bot cannot write to the user at all
/// until they start or unblock it. This is a parse-only fact; private-topic
/// operations other than creation keep propagating their original errors.
public enum PrivateChatUnreachable: String, Error, Equatable, Sendable, CaseIterable,
  CustomStringConvertible
{
  /// The user has blocked the bot.
  case userIsBlocked = "USER_IS_BLOCKED"
  /// The input user has been deactivated.
  case inputUserDeactivated = "INPUT_USER_DEACTIVATED"
  /// The user has been deactivated.
  case userDeactivated = "USER_DEACTIVATED"
  /// The user has been deactivated by a ban.
  case userDeactivatedBan = "USER_DEACTIVATED_BAN"
  /// The peer cannot be used for this request.
  case peerIDInvalid = "PEER_ID_INVALID"
  /// The user is not valid for this bot request.
  case userBotInvalid = "USER_BOT_INVALID"
  /// The bot cannot initiate this chat.
  case botCannotInitiate = "BOT_CANNOT_INITIATE"
  /// Writing to the chat is forbidden.
  case chatWriteForbidden = "CHAT_WRITE_FORBIDDEN"

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
