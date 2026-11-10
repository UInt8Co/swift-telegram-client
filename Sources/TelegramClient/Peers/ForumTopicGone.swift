import MTProtoClientKit

/// Topic errors for which a caller may choose to open a new topic.
/// Includes ``closed``, which can describe a closed but existing topic.
/// This is a parse-only fact; topic operations propagate their original errors.
public enum ForumTopicGone: String, Error, Equatable, Sendable, CaseIterable,
  CustomStringConvertible
{
  /// The topic has been deleted.
  case deleted = "TOPIC_DELETED"
  /// The topic ID is invalid.
  case idInvalid = "TOPIC_ID_INVALID"
  /// The topic is closed, but may still exist.
  case closed = "TOPIC_CLOSED"
  /// The message thread is invalid.
  case messageThreadInvalid = "MESSAGE_THREAD_INVALID"

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
