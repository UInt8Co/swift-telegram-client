/// What this client refuses, as opposed to what the server refuses (an
/// `MTProtoRPCError`) or what the link refuses (an `MTProtoClientError`).
public enum TelegramClientError: Error, Equatable, Sendable, CustomStringConvertible {
  /// The authorization did not produce the kind of account the caller asked
  /// for — a bot token that authorized a user, or the reverse.
  case unexpectedAccountKind
  /// A resumed session proved to belong to a different account than the one it
  /// was filed under.
  case sessionBelongsToAnotherAccount
  /// A connection was told to resume a stored session and the store had none.
  case noStoredSession
  case datacenterNotAdvertised(Int32)
  case tooManyMigrations(Int32)
  case peerNotFound(String)
  case channelRequired(String)
  case monoforumUnsupported(String)
  case missingAccessHash(String)
  case userNotFound(Int64)
  /// `differenceTooLong`: the account is so far behind that the server will not
  /// enumerate what changed, and the caller has to resynchronize from scratch.
  case historyTooLong(String)

  public var description: String {
    switch self {
    case .unexpectedAccountKind:
      "the authorization produced a different kind of account than was asked for"
    case .sessionBelongsToAnotherAccount:
      "the resumed session belongs to a different account"
    case .noStoredSession: "no stored session to resume"
    case .datacenterNotAdvertised(let dcID):
      "the request was redirected to datacenter \(dcID), which is not advertised"
    case .tooManyMigrations(let dcID):
      "the request was redirected to datacenter \(dcID) once too often"
    case .peerNotFound(let value): "peer '\(value)' is not visible to this account"
    case .channelRequired(let value): "'\(value)' is not a channel or supergroup"
    case .monoforumUnsupported(let value):
      "'\(value)' is a monoforum, whose messages belong to a correspondent's topic"
    case .missingAccessHash(let value): "'\(value)' came back without an access hash"
    case .userNotFound(let id): "user \(id) is not visible to this account"
    case .historyTooLong(let value):
      "\(value) is too far behind to be caught up with a difference"
    }
  }
}
