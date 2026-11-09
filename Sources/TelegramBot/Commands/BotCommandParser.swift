import TelegramClient

/// A tokenized explicit bot command. Arguments preserve their interior whitespace.
public struct ParsedBotCommand: Equatable, Sendable {
  /// Lowercase command name without the slash or username suffix.
  public let command: String
  /// Original argument substring, excluding surrounding whitespace and optional guest mentions.
  public let arguments: String?
}

/// Tokenizes explicit commands without interpreting arguments or authorizing execution.
public enum BotCommandParser {
  /// Placement of standalone mentions of the addressed bot.
  public enum GuestMentions: Sendable {
    /// Only a `/command@username` suffix addresses the bot; standalone mentions are arguments.
    case disabled
    /// Remove one mention before the command, one immediately after it, and one at the end.
    /// Interior mentions remain untouched. All matching is case insensitive.
    case adjacentAndTrailing
  }

  /// Parses a slash command, optionally suffixed by the given bot username.
  /// Usernames accept a leading `@`, then 1...32 ASCII letters, digits or underscores,
  /// starting with a letter. Commands are nonempty ASCII letters, digits, `_` or `-`.
  /// Another bot's suffix, invalid usernames and text before the command return nil.
  /// This synchronous operation performs no I/O and preserves interior argument bytes.
  public static func parse(
    _ text: String, botUsername: String, guestMentions: GuestMentions = .disabled
  ) -> ParsedBotCommand? {
    parse(text, botUsernames: [botUsername], guestMentions: guestMentions)
  }

  /// Parses a slash command for a bot with several usernames, such as those from
  /// ``TelegramUsername/active(of:)``. A suffix or guest mention naming any of them
  /// addresses the bot, so each mention position may use a different name.
  /// Invalid names are ignored; without a valid name nothing parses.
  public static func parse(
    _ text: String, botUsernames: some Sequence<String>, guestMentions: GuestMentions = .disabled
  ) -> ParsedBotCommand? {
    let mentions = Set(botUsernames.compactMap { TelegramUsername.normalized($0).map { "@" + $0 } })
    guard !mentions.isEmpty else { return nil }
    func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    func addresses(_ token: Substring?) -> Bool { token.map { mentions.contains($0.lowercased()) } ?? false }
    var tokens = text.split(whereSeparator: \.isWhitespace)[...]
    if guestMentions == .adjacentAndTrailing, addresses(tokens.first) { tokens.removeFirst() }
    guard let first = tokens.first, first.hasPrefix("/") else { return nil }
    var name = String(first.dropFirst()).lowercased()
    if let at = name.firstIndex(of: "@") {
      guard mentions.contains(String(name[at...])) else { return nil }
      name = String(name[..<at])
    }
    guard !name.isEmpty, name.utf8.allSatisfy({ letter($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 })
    else { return nil }
    tokens.removeFirst()
    if guestMentions == .adjacentAndTrailing {
      if addresses(tokens.first) { tokens.removeFirst() }
      if addresses(tokens.last) { tokens.removeLast() }
    }
    let arguments: String?
    if let start = tokens.first?.startIndex, let end = tokens.last?.endIndex {
      arguments = String(text[start..<end])
    } else { arguments = nil }
    return .init(command: name, arguments: arguments)
  }
}
