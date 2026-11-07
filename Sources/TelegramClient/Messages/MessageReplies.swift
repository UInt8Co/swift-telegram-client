import TelegramSchema

/// Pure reply construction using explicit destination context. No peer or topic
/// is inferred, and no IDs (including 1) are treated as special sentinels.
public enum MessageReplies {
  /// Replies to an ordinary message in the destination, optionally in a topic.
  /// No rich-message quote is added; callers can put quotations in the body.
  public static func message(_ id: Int32, topicID: Int32? = nil) -> TL.InputReplyToType {
    .inputReplyToMessage(.init(replyToMsgId: id, topMsgId: topicID))
  }

  /// Replies across peers without importing the source's topic. Only an
  /// explicitly supplied destination topic becomes the reply's top message ID.
  public static func external(messageID: Int32, sourcePeer: TL.InputPeerType,
    destinationTopicID: Int32? = nil) -> TL.InputReplyToType {
    .inputReplyToMessage(.init(replyToMsgId: messageID, topMsgId: destinationTopicID, replyToPeerId: sourcePeer))
  }

  /// Targets a topic's root message, or returns nil for no explicit topic.
  public static func topic(_ id: Int32?) -> TL.InputReplyToType? {
    id.map { message($0) }
  }
}
