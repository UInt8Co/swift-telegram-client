import MTProtoClientKit

/// Narrow content-related RPC facts. They do not authorize copying or retrying.
public enum MessageContentRejection {
  /// The RPC explicitly prohibits forwarding protected content (400/403/406).
  public static func protectedForward(_ error: any Error) -> Bool {
    guard let rpc = error as? MTProtoRPCError, [400, 403, 406].contains(rpc.code) else { return false }
    return rpc.message == "CHAT_FORWARDS_RESTRICTED"
  }
  /// Recognizes listed media/entity refusals at codes 400, 403 and 406.
  /// This includes permissions and stale references, not a fallback policy.
  public static func mediaOrEntities(_ error: any Error) -> Bool {
    guard let rpc = error as? MTProtoRPCError, [400, 403, 406].contains(rpc.code) else { return false }
    return rpc.message.hasPrefix("FILE_REFERENCE_") || ["MEDIA_EMPTY", "MEDIA_INVALID",
      "MEDIA_FILE_INVALID", "PHOTO_INVALID", "DOCUMENT_INVALID", "CHAT_SEND_MEDIA_FORBIDDEN", "CHAT_SEND_PHOTOS_FORBIDDEN",
      "CHAT_SEND_VIDEOS_FORBIDDEN", "CHAT_SEND_AUDIOS_FORBIDDEN", "CHAT_SEND_VOICES_FORBIDDEN",
      "CHAT_SEND_DOCS_FORBIDDEN", "CHAT_SEND_STICKERS_FORBIDDEN", "CHAT_SEND_GIFS_FORBIDDEN",
      "CHAT_SEND_ROUNDVIDEOS_FORBIDDEN", "CHAT_SEND_POLL_FORBIDDEN", "CHAT_SEND_GAME_FORBIDDEN",
      "CHAT_SEND_WEBPAGE_FORBIDDEN", "VOICE_MESSAGES_FORBIDDEN", "WEBPAGE_MEDIA_EMPTY",
      "WEBPAGE_NOT_FOUND", "WEBPAGE_URL_INVALID",
      "CHAT_FORWARDS_RESTRICTED", "ENTITY_BOUNDS_INVALID", "ENTITY_MENTION_USER_INVALID",
      "CUSTOM_EMOJI_INVALID", "PREMIUM_ACCOUNT_REQUIRED", "MEDIA_CAPTION_TOO_LONG"].contains(rpc.message)
  }

  /// Recognizes only code 400 rich-text/depth validation refusals.
  public static func richMessage(_ error: any Error) -> Bool {
    guard let rpc = error as? MTProtoRPCError, rpc.code == 400 else { return false }
    return ["RICH_MESSAGE_RICH_TEXT_INVALID", "RICH_MESSAGE_RICH_TEXT_UNSUPPORTED",
      "RICH_MESSAGE_DEPTH_INVALID"].contains(rpc.message)
  }

}
