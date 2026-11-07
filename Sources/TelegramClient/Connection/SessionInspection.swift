#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Secret-free, point-in-time inspection of stored sessions. No credentials, account
/// values or error descriptions are retained. Inspection does not modify storage.
public enum SessionInspection {
  /// Status of one datacenter's stored session.
  public enum Status: Sendable, Equatable {
    /// No stored session exists.
    case missing
    /// A session exists. Nil expiry means a permanent key; negative seconds mean expired.
    case stored(accountMatches: Bool, expiresInSeconds: Int64?)
    /// Storage threw while reading. Neither the error nor its contents are exposed.
    case unreadable
  }

  /// One datacenter and its derived status.
  public struct Entry: Sendable, Equatable {
    /// Inspected datacenter identifier.
    public let dcID: Int32
    /// Opaque session storage key, containing only caller scope and datacenter identity.
    public let key: String
    /// Secret-free status at inspection time.
    public let status: Status
  }

  /// Inspects distinct datacenter IDs in ascending order, reading each once. A failed
  /// read becomes `unreadable` and does not abort other reads. Cancellation thrown by
  /// storage is also represented as unreadable; this diagnostic is best-effort.
  public static func inspect(sessions: any TelegramSessionStore, scope: String,
    expectedAccountID: Int64?, dcIDs: [Int32], now: Date = .now) async -> [Entry] {
    var result: [Entry] = []
    for dcID in Set(dcIDs).sorted() {
      let key = TelegramConnection.sessionKey(scope: scope, dcID: dcID)
      let status: Status
      do {
        if let cached = try await sessions.session(for: key) {
          status = .stored(accountMatches: cached.accountID == expectedAccountID,
            expiresInSeconds: cached.session.expiresAt == 0 ? nil
              : Int64(cached.session.expiresAt) - Int64(now.timeIntervalSince1970))
        } else { status = .missing }
      } catch { status = .unreadable }
      result.append(Entry(dcID: dcID, key: key, status: status))
    }
    return result
  }
}
