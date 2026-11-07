import TelegramSchema

/// Replies in the bot ephemeral-message namespace, separate from ordinary IDs.
public enum EphemeralReplies {
  /// Constructs a reply to an ephemeral message. Its topic context is not copied
  /// into the ordinary message namespace. This performs no availability check.
  public static func message(_ id: Int32) -> TL.InputReplyToType {
    .inputReplyToEphemeralMessage(.init(id: id))
  }
}
