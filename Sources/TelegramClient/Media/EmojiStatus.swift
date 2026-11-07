import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Projection of regular and collectible emoji statuses.
public enum EmojiStatus {
  /// Returns the displayed document ID, excluding statuses expired at `now`.
  public static func documentID(_ status: TL.EmojiStatusType?, now: Date = Date()) -> Int64? {
    switch status {
    case .emojiStatus(let value):
      return value.until.map { Double($0) <= now.timeIntervalSince1970 } == true
        ? nil : value.documentId
    case .emojiStatusCollectible(let value):
      return value.until.map { Double($0) <= now.timeIntervalSince1970 } == true
        ? nil : value.documentId
    default: return nil
    }
  }
}
