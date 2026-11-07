import TelegramSchema

/// Interprets peer-scoped message replies without fetching messages.
public enum ReplyResolver {
  /// A validated local forum destination; see `ForumTopics.TopicIDPolicy.localReply`.
  public static func topicID(for message: TL.Message) -> Int32? {
    ForumTopics.topicID(of: .message(message), policy: .localReply)
  }

  /// Returns a positive reply address, using an explicit external peer when present.
  /// Scheduled replies have a separate ID space and return nil.
  public static func address(for message: TL.Message) -> MessageAddress? {
    guard case .messageReplyHeader(let reply) = message.replyTo,
       let id = reply.replyToMsgId, id > 0, !reply.replyToScheduled else { return nil }
    return .init(peer: PeerID(reply.replyToPeerId ?? message.peerId), id: id)
  }

  /// Only an explicit forwarded author establishes identity; display names do not.
  public static func quotedAuthor(for message: TL.Message) -> PeerID? {
    guard case .messageReplyHeader(let reply) = message.replyTo,
       let author = reply.replyFrom?.fromId else { return nil }
    return PeerID(author)
  }
}
