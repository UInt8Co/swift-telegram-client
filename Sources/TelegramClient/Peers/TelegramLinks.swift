import TelegramSchema
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Telegram ASCII username grammar with explicit strict and permissive entry points.
public enum TelegramUsername {
  /// Checks a nonempty raw name consisting only of ASCII letters, digits and underscores.
  /// This permissive grammar preserves configuration and bot-link compatibility;
  /// it does not establish that Telegram will register the name.
  public static func isValid(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { byte in
      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
    }
  }

  /// Removes one leading @ and lowercases a 1...32 byte name beginning with a letter.
  public static func normalized(_ value: String) -> String? {
    let candidate = value.hasPrefix("@") ? String(value.dropFirst()) : value
    let bytes = candidate.utf8
    func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    guard (1...32).contains(bytes.count), let first = bytes.first, letter(first),
       isValid(candidate) else { return nil }
    return candidate.lowercased()
  }
}

/// Recognized public Telegram link destinations. This is not a complete deep-link router.
public enum TelegramLinkDestination: Hashable, Sendable {
  /// A lowercase public username.
  case username(String)
  /// A positive numeric user ID from an explicit tg://user route.
  case user(Int64)
  /// A lowercase sticker pack short name.
  case stickerSet(String)
  /// A lowercase custom-emoji pack short name.
  case emojiSet(String)
}

/// Parses Telegram destinations independently of application URL identity rules.
public enum TelegramLink {
  /// Normalizes a 1...64 byte ASCII pack name starting with a letter.
  public static func packName(_ value: String) -> String? {
    let bytes = value.utf8
    func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    guard (1...64).contains(bytes.count), let first = bytes.first, letter(first),
       bytes.allSatisfy({ letter($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
    return value.lowercased()
  }

  /// Parses a raw link. Schemeless web links default to HTTPS. Numeric user routes
  /// are validated before any caller normalization; malformed or unknown routes return no destination.
  public static func destinations(inURL value: String) -> Set<TelegramLinkDestination> {
    var input = String(value.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    guard !input.contains(where: \.isWhitespace) else { return [] }
    if input.hasPrefix("//") { input = "https:" + input }
    if !input.contains("://") { input = "https://" + input }
    guard let components = URLComponents(string: input),
      ["http", "https", "ftp", "tg"].contains(components.scheme?.lowercased() ?? "") else { return [] }
    var result = destinations(in: components)
    if let id = telegramUserID(inURL: value) { result.insert(.user(id)) }
    return result
  }

  /// Reads public usernames and pack routes from supplied components. Callers may
  /// apply their own URL normalization first. Numeric user IDs deliberately use
  /// `telegramUserID(inURL:)` instead, because normalization can erase invalid syntax.
  public static func destinations(in components: URLComponents) -> Set<TelegramLinkDestination> {
    var result: Set<TelegramLinkDestination> = []
    let host = components.host?.lowercased()
    let scheme = components.scheme?.lowercased()
    if scheme == "tg", host == "resolve",
       let domain = components.queryItems?.first(where: { $0.name.lowercased() == "domain" })?.value,
       let name = TelegramUsername.normalized(domain) { result.insert(.username(name)) }
    if scheme == "tg", host == "addstickers" || host == "addemoji",
       let set = components.queryItems?.first(where: { $0.name.lowercased() == "set" })?.value,
       let name = packName(set) {
      result.insert(host == "addemoji" ? .emojiSet(name) : .stickerSet(name))
    }
    if ["t.me", "telegram.me", "www.t.me", "www.telegram.me"].contains(host ?? "") {
      let parts = components.path.split(separator: "/").map(String.init)
      if parts.count >= 2, ["addstickers", "addemoji"].contains(parts[0].lowercased()), let name = packName(parts[1]) {
        result.insert(parts[0].lowercased() == "addemoji" ? .emojiSet(name) : .stickerSet(name))
      }
      // Known non-username routes; not an exhaustive list of Telegram actions.
      let reserved: Set<String> = ["c", "s", "joinchat", "addstickers", "addemoji", "addtheme", "setlanguage", "share", "iv", "proxy", "socks", "login", "confirmphone", "boost", "contact", "invoice", "giftcode", "m", "nft", "addlist", "bg"]
      let candidate = parts.first == "s" ? parts.dropFirst().first : parts.first
      if let candidate, !reserved.contains(candidate.lowercased()), let name = TelegramUsername.normalized(candidate) {
        result.insert(.username(name))
      }
    }
    return result
  }

  /// Accepts only an explicit tg://user route with one positive ASCII-decimal id.
  /// Rejects credentials, ports, paths, trailing host dots, duplicate IDs and overflow.
  public static func telegramUserID(inURL value: String) -> Int64? {
    let input = String(value.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    guard validPercentEncoding(input),
       let components = URLComponents(string: input),
       components.scheme?.lowercased() == "tg",
       components.percentEncodedHost?.lowercased() == "user",
       components.user == nil, components.password == nil, components.port == nil,
       components.percentEncodedPath.isEmpty else { return nil }
    // Query items decode percent escapes once. Reject ambiguous duplicate
    // IDs, signs, whitespace, non-ASCII digits and values outside Int64.
    let ids = (components.queryItems ?? []).filter { $0.name == "id" }
    guard ids.count == 1, let value = ids[0].value, !value.isEmpty,
       value.utf8.allSatisfy({ (48...57).contains($0) }),
       let id = Int64(value), id > 0 else { return nil }
    return id
  }

  // Validate every escape and decoded UTF-8 byte before URLComponents can repair input.
  private static func validPercentEncoding(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    var decoded: [UInt8] = []
    var index = 0
    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 48...57: byte - 48
      case 65...70: byte - 55
      case 97...102: byte - 87
      default: nil
      }
    }
    while index < bytes.count {
      if bytes[index] == 37 {
        guard index + 2 < bytes.count, let high = nibble(bytes[index + 1]),
          let low = nibble(bytes[index + 2]) else { return false }
        decoded.append(high * 16 + low)
        index += 3
      } else { decoded.append(bytes[index]); index += 1 }
    }
    return String(validating: decoded, as: UTF8.self) != nil
  }

}
