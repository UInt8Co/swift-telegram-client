import TelegramSchema

/// Shared title, icon and reply helpers for Telegram forums, including private topics.
public enum ForumTopics {
  /// Telegram's maximum topic title length, in UTF-8 bytes.
  public static let maxTitleLength = 128

  /// The only icon colours Telegram accepts for a new topic.
  public static let iconColors: [Int32] = [
    0x6FB9F0, 0xFFD67E, 0xCB86DB, 0x8EEE98, 0xFF93B2, 0xFB6F5F,
  ]

  /// A title Telegram accepts: control characters dropped, whitespace
  /// collapsed, cut at a character boundary to `maxTitleLength` UTF-8
  /// bytes, never empty.
  public static func title(_ text: String, fallback: String = "Topic") -> String {
    let collapsed = clean(text)
    let fallback = clean(fallback)
    let base = collapsed.isEmpty ? (fallback.isEmpty ? "Topic" : fallback) : collapsed
    guard base.utf8.count > maxTitleLength else { return base }
    let ellipsis = "…"
    var result = ""
    for character in base {
      guard result.utf8.count + character.utf8.count + ellipsis.utf8.count <= maxTitleLength else {
        break
      }
      result.append(character)
    }
    return result + ellipsis
  }

  private static func clean(_ text: String) -> String {
    // Control characters other than whitespace become separators.
    let visible = String(
      String.UnicodeScalarView(
        text.unicodeScalars.map {
          $0.properties.generalCategory == .control ? " " : $0
        }))
    return visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// A stable colour for one key, such as a group's ID.
  public static func iconColor(for key: Int64) -> Int32 {
    iconColors[Int(UInt64(bitPattern: key) % UInt64(iconColors.count))]
  }

  /// Places a new message in a topic, or replies inside it.
  public static func replyTo(topic: Int32, message: Int32? = nil) -> TL.InputReplyToType {
    .inputReplyToMessage(.init(replyToMsgId: message ?? topic, topMsgId: topic))
  }

  /// How reply headers are interpreted when locating a forum topic.
  public enum TopicIDPolicy: Sendable {
    /// Preserve raw header values, including scheduled/external and nonpositive IDs.
    case header
    /// Reject scheduled and nonpositive IDs. External replies require an explicit top ID.
    case localReply
  }

  /// The topic a received message belongs to, when its header marks a forum reply.
  /// Creation messages use their private-topic header ID or supergroup service ID.
  /// This preserves header values without validating scheduled or external replies.
  public static func topicID(of message: TL.MessageType, policy: TopicIDPolicy = .header) -> Int32? {
    let header: TL.MessageReplyHeaderType?
    switch message {
    case .message(let value): header = value.replyTo
    case .messageService(let value):
      if case .messageActionTopicCreate = value.action { return createdTopicID(of: value) }
      header = value.replyTo
    case .messageEmpty: return nil
    }
    guard case .messageReplyHeader(let reply)? = header, reply.forumTopic else { return nil }
    switch policy {
    case .header: return reply.replyToTopId ?? reply.replyToMsgId
    case .localReply:
      guard !reply.replyToScheduled else { return nil }
      if let id = reply.replyToTopId { return id > 0 ? id : nil }
      let peer: TL.PeerType
      switch message {
      case .message(let value): peer = value.peerId
      case .messageService(let value): peer = value.peerId
      case .messageEmpty: return nil
      }
      guard reply.replyToPeerId == nil || reply.replyToPeerId == peer,
        let id = reply.replyToMsgId, id > 0 else { return nil }
      return id
    }
  }

  /// The topic a `messageActionTopicCreate` service message opened: its
  /// header's `reply_to_top_id` in a private chat, else (as in supergroups)
  /// the service message's own ID.
  public static func createdTopicID(of service: TL.MessageService) -> Int32 {
    if case .messageReplyHeader(let reply)? = service.replyTo, reply.forumTopic,
      let id = reply.replyToTopId, id > 0
    {
      return id
    }
    return service.id
  }

  /// Recognizes topic errors for which a caller may choose to open a new topic.
  /// Includes `TOPIC_CLOSED`, which can describe a closed but existing topic.
  public static func isTopicGone(errorMessage: String) -> Bool {
    ["TOPIC_DELETED", "TOPIC_ID_INVALID", "TOPIC_CLOSED", "MESSAGE_THREAD_INVALID"].contains(
      errorMessage)
  }

}
