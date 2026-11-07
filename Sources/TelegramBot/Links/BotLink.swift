import TelegramSchema
import TelegramClient

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Telegram bot start parameters use at most 64 URL-safe ASCII characters.
public enum BotLink {
  /// Permission names used by Telegram's group/channel bot links.
  public enum AdminRight: String, CaseIterable, Sendable {
    /// Change chat information.
    case changeInfo = "change_info"
    /// Post channel messages.
    case postMessages = "post_messages"
    /// Edit channel messages.
    case editMessages = "edit_messages"
    /// Delete messages.
    case deleteMessages = "delete_messages"
    /// Restrict chat members.
    case banUsers = "restrict_members"
    /// Invite users.
    case inviteUsers = "invite_users"
    /// Pin messages.
    case pinMessages = "pin_messages"
    /// Manage forum topics.
    case manageTopics = "manage_topics"
    /// Promote members.
    case addAdmins = "promote_members"
    /// Manage video chats.
    case manageCall = "manage_video_chats"
    /// Remain anonymous.
    case anonymous
    /// Manage the chat.
    case other = "manage_chat"
    /// Post stories.
    case postStories = "post_stories"
    /// Edit stories.
    case editStories = "edit_stories"
    /// Delete stories.
    case deleteStories = "delete_stories"
    /// Manage direct messages.
    case manageDirectMessages = "manage_direct_messages"
    /// Manage member tags.
    case manageRanks = "manage_tags"
  }

  /// Encodes bytes as canonical unpadded URL-safe base64 after a literal prefix.
  /// Returns nil unless the complete parameter is 1...64 URL-safe ASCII bytes.
  public static func encodeStartParameter(_ payload: Data, prefix: String = "") -> String? {
    let encoded = String(
      payload.base64EncodedString().filter { $0 != "=" }.map {
        $0 == "+" ? "-" : $0 == "/" ? "_" : $0
      })
    let parameter = prefix + encoded
    return validParameter(parameter) ? parameter : nil
  }

  /// Decodes a canonical parameter with the required literal prefix.
  /// Rejects malformed, noncanonical or out-of-range parameters.
  public static func decodeStartParameter(_ parameter: String, prefix: String = "") -> Data? {
    guard validParameter(parameter), parameter.hasPrefix(prefix) else { return nil }
    var encoded = String(
      parameter.dropFirst(prefix.count).map { $0 == "-" ? "+" : $0 == "_" ? "/" : $0 })
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded),
      encodeStartParameter(data, prefix: prefix) == parameter
    else { return nil }
    return data
  }

  /// Builds a private-chat start link, or returns nil for invalid input.
  /// A leading `@` is accepted in the username.
  public static func startURL(botUsername: String, parameter: String) -> String? {
    guard let username = username(botUsername), validParameter(parameter) else { return nil }
    return "https://t.me/\(username)?start=\(parameter)"
  }

  /// Builds a group start link, preserving permission order and removing duplicates.
  /// Returns nil for invalid usernames or parameters.
  /// See <https://core.telegram.org/api/links#group-channel-bot-links>.
  public static func startGroupURL(
    botUsername: String, parameter: String, adminRights: [AdminRight]
  ) -> String? {
    guard let username = username(botUsername), validParameter(parameter) else { return nil }
    var seen = Set<AdminRight>()
    let rights = adminRights.filter { seen.insert($0).inserted }.map(\.rawValue).joined(
      separator: "+")
    let admin = rights.isEmpty ? "" : "&admin=\(rights)"
    return "https://t.me/\(username)?startgroup=\(parameter)\(admin)"
  }

  /// Creates a native inline URL button with literal text and the supplied URL.
  public static func urlButton(_ text: String, url: String) -> TL.KeyboardInlineButton {
    .init(text: text, type: .inlineButtonTypeUrl(.init(url: url)))
  }

  private static func ascii(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
      || byte == 45
  }

  private static func username(_ value: String) -> String? {
    let username = value.hasPrefix("@") ? String(value.dropFirst()) : value
    return TelegramUsername.isValid(username) ? username : nil
  }

  private static func validParameter(_ parameter: String) -> Bool {
    (1...64).contains(parameter.utf8.count) && parameter.utf8.allSatisfy(ascii)
  }
}
