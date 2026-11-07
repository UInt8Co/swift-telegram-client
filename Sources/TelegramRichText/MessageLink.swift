import TelegramSchema

/// A native inline link to a message. Opening it still depends on the reader's
/// membership, access, and Telegram client support for the URL scheme.
public struct MessageLink: InlineContent {
  /// The rendered label and URL; this component does not add reference markers.
  public let richText: TL.RichTextType

  /// Creates a link for an explicit peer/message pair. The default label is the
  /// decimal message ID. Channel links use t.me/c; chats/users use openmessage.
  public init(peer: TL.PeerType, messageID: Int32, label: String? = nil) {
    let url: String
    switch peer {
    case .peerChannel(let value): url = "https://t.me/c/\(value.channelId)/\(messageID)"
    case .peerChat(let value): url = "tg://openmessage?chat_id=\(value.chatId)&message_id=\(messageID)"
    case .peerUser(let value): url = "tg://openmessage?user_id=\(value.userId)&message_id=\(messageID)"
    }
    richText = Text(label ?? String(messageID)).link(to: url).richText
  }
}
