#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramSchema

/// Pack titles can change. Reuse metadata briefly, without retaining the full
/// sticker documents returned by Telegram or caching transient RPC failures.
public actor StickerSetCache {
  private struct Entry {
    var set: TL.StickerSet?
    var expiresAt: Date
  }
  private var entries: [String: Entry] = [:]
  private let fetch: @Sendable (TL.InputStickerSetType) async throws -> TL.StickerSet?

  private let lifetime: TimeInterval
  private let capacity: Int

  /// Creates a metadata cache. The default lifetime is five minutes.
  /// At capacity the cache clears before inserting a result and up to three aliases;
  /// capacity is therefore a clearing threshold, not a strict entry limit.
  /// Concurrent misses are independent; errors are not cached, missing sets are.
  public init(lifetime: TimeInterval = 300, capacity: Int = 10_000, fetch: @escaping @Sendable (TL.InputStickerSetType) async throws -> TL.StickerSet?) {
    precondition(lifetime >= 0 && capacity > 0)
    self.lifetime = lifetime; self.capacity = capacity
    self.fetch = fetch
  }

  /// Reads fresh ID/hash or case-insensitive name metadata without fetching.
  public func cached(_ reference: TL.InputStickerSetType, now: Date = Date()) -> TL.StickerSet? {
    let key: String
    switch reference {
    case .inputStickerSetID(let set): key = "id:\(set.id):\(set.accessHash)"
    case .inputStickerSetShortName(let set): key = "name:\(set.shortName.lowercased())"
    default: return nil
    }
    guard let entry = entries[key], entry.expiresAt > now else { return nil }
    return entry.set
  }

  /// Fetches fresh metadata. Empty references return nil; special references bypass caching.
  /// The fetch runs in the caller task and owns cancellation. Expiry starts at `now`.
  public func value(for reference: TL.InputStickerSetType, now: Date = Date()) async throws -> TL.StickerSet? {
    let key: String
    switch reference {
    case .inputStickerSetEmpty: return nil
    case .inputStickerSetID(let set): key = "id:\(set.id):\(set.accessHash)"
    case .inputStickerSetShortName(let set): key = "name:\(set.shortName.lowercased())"
    default: return try await fetch(reference)
    }
    if let entry = entries[key], entry.expiresAt > now { return entry.set }
    let set = try await fetch(reference)
    if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
    let entry = Entry(set: set, expiresAt: now.addingTimeInterval(lifetime))
    entries[key] = entry
    if let set {
      entries["id:\(set.id):0"] = entry
      entries["id:\(set.id):\(set.accessHash)"] = entry
      entries["name:\(set.shortName.lowercased())"] = entry
    }
    return set
  }
}
