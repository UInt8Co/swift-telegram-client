import TelegramSchema

/// A desired command list for one caller-defined scope and language key.
public struct BotCommandList: Sendable {
  /// Language code passed to Telegram; an empty string selects the fallback list.
  public let languageCode: String
  /// Commands in their desired display order.
  public let commands: [TL.BotCommand]
  /// Caller-defined version covering every relevant command, language and scope change.
  public let signature: String

  /// Creates a list without computing a signature or validating Telegram's server limits.
  public init(languageCode: String = "", commands: [TL.BotCommand], signature: String) {
    self.languageCode = languageCode
    self.commands = commands
    self.signature = signature
  }
}

/// Plans changed and obsolete command lists using caller-owned publication receipts.
/// Keys must uniquely identify both scope and language. No I/O or persistence is performed.
public struct BotCommandPublication<Key: Hashable & Sendable>: Sendable {
  /// Successfully published signatures by scope/language key.
  public var published: [Key: String]
  /// Lists awaiting cleanup, including receipts retained after failed resets.
  public var obsolete: Set<Key>

  /// Restores receipts from caller storage. Do not discard receipts merely because access is unavailable.
  public init(published: [Key: String] = [:], obsolete: Set<Key> = []) {
    self.published = published
    self.obsolete = obsolete
  }

  /// Returns pending publications and resets in caller-defined strict order.
  /// `isAvailable` gates both operations; `canPublish` gates only publication prerequisites.
  /// Refusing publication does not prove resetting is impossible. Neither closure deletes receipts.
  /// The caller executes operations, records successful signatures, removes cleared receipts,
  /// and persists that result; failed operations retain their previous receipts for retry.
  public func plan(
    desired: [Key: BotCommandList], isAvailable: (Key) -> Bool = { _ in true },
    canPublish: (Key) -> Bool = { _ in true }, orderedBefore: (Key, Key) -> Bool
  ) -> (publish: [Key], revoke: [Key]) {
    let keys = Set(desired.keys)
    let publish = keys.filter {
      published[$0] != desired[$0]?.signature && isAvailable($0) && canPublish($0)
    }
    let revoke = Set(published.keys).union(obsolete).subtracting(keys).filter(isAvailable)
    return (publish.sorted(by: orderedBefore), revoke.sorted(by: orderedBefore))
  }
}
