import TelegramClient
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct CustomEmojiCacheTests {
  @Test func expiredStatusEmojiIsNotDisplayed() {
    let now = Date(timeIntervalSince1970: 100)
    #expect(EmojiStatus.documentID(.emojiStatus(.init(documentId: 8, until: 99)), now: now) == nil)
    #expect(EmojiStatus.documentID(.emojiStatus(.init(documentId: 8, until: 100)), now: now) == nil)
    #expect(EmojiStatus.documentID(.emojiStatus(.init(documentId: 8, until: 101)), now: now) == 8)
    #expect(EmojiStatus.documentID(.emojiStatus(.init(documentId: 8)), now: now) == 8)
    #expect(EmojiStatus.documentID(nil, now: now) == nil)
  }
  @Test func collectibleStatusUsesTheSameExpiryBoundary() {
    var status = TL.EmojiStatusCollectible(
      collectibleId: 1, documentId: 8, title: "Gift", slug: "gift",
      patternDocumentId: 9, centerColor: 0, edgeColor: 0, patternColor: 0, textColor: 0, until: 100)
    let now = Date(timeIntervalSince1970: 100)
    #expect(EmojiStatus.documentID(.emojiStatusCollectible(status), now: now) == nil)
    status.until = 101
    #expect(EmojiStatus.documentID(.emojiStatusCollectible(status), now: now) == 8)
  }

  @Test func batchesSortedUniqueIDsAndReusesAttributes() async throws {
    let fetcher = EmojiFetcher()
    let cache = CustomEmojiCache { try await fetcher.fetch($0) }
    let ids = Array((1...401).reversed()).map(Int64.init) + [1, 401]
    #expect(try await cache.sets(documentIDs: ids).count == 401)
    #expect(await fetcher.calls.map(\.count) == [200, 200, 1])
    #expect(await fetcher.calls.first == Array(1...200).map(Int64.init))
    #expect(try await cache.attribute(documentID: 1)?.alt == "one")
    #expect(await cache.cachedSets(documentIDs: [1, 2]).count == 2)
    #expect(await fetcher.calls.count == 3)
    #expect(await cache.cachedSets(documentIDs: [9_999]).isEmpty)
  }

  @Test func expiryCapacityMissingAndErrorsAreExplicit() async throws {
    let fetcher = EmojiFetcher()
    let now = Date(timeIntervalSince1970: 100)
    let cache = CustomEmojiCache(lifetime: 10, capacity: 1) { try await fetcher.fetch($0) }
    _ = try await cache.attribute(documentID: 1, now: now)
    #expect(await cache.cachedSets(documentIDs: [1], now: now.addingTimeInterval(9)).count == 1)
    #expect(await cache.cachedSets(documentIDs: [1], now: now.addingTimeInterval(10)).isEmpty)
    _ = try await cache.attribute(documentID: 2, now: now)
    #expect(await cache.cachedSets(documentIDs: [1], now: now).isEmpty)
    await fetcher.configure(missing: true)
    #expect(try await cache.attribute(documentID: 3, now: now) == nil)
    #expect(try await cache.attribute(documentID: 3, now: now) == nil)
    await fetcher.configure(fail: true)
    await #expect(throws: CancellationError.self) {
      try await cache.attribute(documentID: 3, now: now)
    }
    await fetcher.configure()
    #expect(try await cache.attribute(documentID: 3, now: now) != nil)
    #expect(await fetcher.calls.count == 6)
  }

  @Test func emptySetAttributesAreCachedButNotReturnedAsSets() async throws {
    let fetcher = EmojiFetcher()
    let cache = CustomEmojiCache { try await fetcher.fetch($0) }
    #expect(try await cache.sets(documentIDs: [0]).isEmpty)
    #expect(try await cache.attribute(documentID: 0) != nil)
    #expect(await fetcher.calls.count == 1)
  }
}

private actor EmojiFetcher {
  var calls: [[Int64]] = []
  var missing = false
  var fail = false
  func configure(missing: Bool = false, fail: Bool = false) {
    self.missing = missing
    self.fail = fail
  }
  func fetch(_ ids: [Int64]) throws -> [TL.DocumentType] {
    calls.append(ids)
    if fail { throw CancellationError() }
    if missing { return [] }
    // Unrequested documents must never populate the cache.
    return (ids + [9_999]).map { id in
      let set: TL.InputStickerSetType =
        id == 0 ? .inputStickerSetEmpty(.init()) : .inputStickerSetID(.init(id: id, accessHash: 1))
      return .document(
        .init(
          id: id, accessHash: 1, fileReference: Data(), date: 1,
          mimeType: "image/webp", size: 1, dcId: 1,
          attributes: [
            .documentAttributeCustomEmoji(.init(alt: "one", stickerset: set)),
            .documentAttributeCustomEmoji(.init(alt: "two", stickerset: set)),
          ]))
    }
  }
}
