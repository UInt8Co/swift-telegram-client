import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Caches custom-emoji attributes, never whole documents or missing results.
/// Concurrent misses are independent; each fetch runs in the calling task and
/// propagates errors and cancellation. A successful earlier batch remains cached
/// if a later batch fails. Use one instance per account when access may differ.
public actor CustomEmojiCache {
  private struct Entry {
    var attribute: TL.DocumentAttributeCustomEmoji
    var expiresAt: Date?
  }
  private var entries: [Int64: Entry] = [:]
  private let lifetime: TimeInterval?
  private let capacity: Int
  private let batchSize: Int
  private let fetch: @Sendable ([Int64]) async throws -> [TL.DocumentType]

  /// Creates a cache. Nil lifetime retains attributes until capacity eviction.
  /// Capacity must be positive; reaching it clears all entries before insertion.
  /// Batch size must be 1...200, Telegram's custom-emoji document request limit.
  public init(
    lifetime: TimeInterval? = nil, capacity: Int = 10_000, batchSize: Int = 200,
    fetch: @escaping @Sendable ([Int64]) async throws -> [TL.DocumentType]
  ) {
    precondition(lifetime.map { $0 >= 0 } ?? true)
    precondition(capacity > 0 && (1...200).contains(batchSize))
    self.lifetime = lifetime
    self.capacity = capacity
    self.batchSize = batchSize
    self.fetch = fetch
  }

  /// Creates a cache backed by messages.getCustomEmojiDocuments on the supplied client.
  public init(
    api: TLClient, lifetime: TimeInterval? = nil, capacity: Int = 10_000, batchSize: Int = 200
  ) {
    self.init(
      lifetime: lifetime, capacity: capacity, batchSize: batchSize,
      fetch: { try await api.messages.getCustomEmojiDocuments(documentId: $0) })
  }

  private func cached(_ id: Int64, now: Date) -> TL.DocumentAttributeCustomEmoji? {
    guard let entry = entries[id], entry.expiresAt.map({ $0 > now }) ?? true else { return nil }
    return entry.attribute
  }

  /// Resolves one attribute, preserving the first custom-emoji attribute in its document.
  /// Missing or non-emoji documents are not cached. Expiry starts at the supplied `now`.
  public func attribute(documentID: Int64, now: Date = Date()) async throws -> TL
    .DocumentAttributeCustomEmoji?
  {
    if let cached = cached(documentID, now: now) { return cached }
    let documents = try await fetch([documentID])
    for case .document(let document) in documents where document.id == documentID {
      for case .documentAttributeCustomEmoji(let attribute) in document.attributes {
        insert(attribute, id: documentID, now: now)
        return attribute
      }
    }
    return nil
  }

  /// Returns only fresh cached set references; empty set references are excluded.
  public func cachedSets(documentIDs: [Int64], now: Date = Date()) -> [Int64: TL
    .InputStickerSetType]
  {
    var result: [Int64: TL.InputStickerSetType] = [:]
    for id in documentIDs {
      if let attribute = cached(id, now: now), let set = Self.set(attribute) { result[id] = set }
    }
    return result
  }

  /// Fetches uncached unique IDs in ascending order and sequential batches.
  /// Only requested documents are used. Empty set references are excluded from the result.
  public func sets(documentIDs: [Int64], now: Date = Date()) async throws -> [Int64: TL
    .InputStickerSetType]
  {
    var attributes: [Int64: TL.DocumentAttributeCustomEmoji] = [:]
    var missing: [Int64] = []
    for id in Set(documentIDs).sorted() {
      if let cached = cached(id, now: now) { attributes[id] = cached } else { missing.append(id) }
    }
    for start in stride(from: 0, to: missing.count, by: batchSize) {
      let chunk = Array(missing[start..<min(start + batchSize, missing.count)])
      let documents = try await fetch(chunk)
      for case .document(let document) in documents where chunk.contains(document.id) {
        for case .documentAttributeCustomEmoji(let attribute) in document.attributes {
          insert(attribute, id: document.id, now: now)
          attributes[document.id] = attribute
          break
        }
      }
    }
    return attributes.compactMapValues(Self.set)
  }

  private func insert(_ attribute: TL.DocumentAttributeCustomEmoji, id: Int64, now: Date) {
    if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
    entries[id] = Entry(
      attribute: attribute, expiresAt: lifetime.map { now.addingTimeInterval($0) })
  }

  private static func set(_ attribute: TL.DocumentAttributeCustomEmoji) -> TL.InputStickerSetType? {
    if case .inputStickerSetEmpty = attribute.stickerset { return nil }
    return attribute.stickerset
  }
}
