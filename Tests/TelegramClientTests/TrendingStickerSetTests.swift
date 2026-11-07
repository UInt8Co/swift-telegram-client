import TelegramClient
import TelegramSchema
import Testing

@Suite struct TrendingStickerSetTests {
  @Test func featuredListsYieldEveryCoveredVariant() {
    let sticker = TL.StickerSet(
      id: 10, accessHash: 1, title: "Cats", shortName: "CatPack", count: 3, hash: 0)
    let emoji = TL.StickerSet(
      emojis: true, id: 11, accessHash: 1, title: "Ducks", shortName: "DuckEmoji", count: 3, hash: 0
    )
    let unnamed = TL.StickerSet(
      id: 12, accessHash: 1, title: "No name", shortName: "", count: 1, hash: 0)
    let empty = TL.DocumentType.documentEmpty(.init(id: 1))
    let response = TL.Messages.FeaturedStickersType.featuredStickers(
      .init(
        hash: 0, count: 4,
        sets: [
          .stickerSetCovered(.init(set: sticker, cover: empty)),
          .stickerSetMultiCovered(.init(set: emoji, covers: [])),
          .stickerSetFullCovered(.init(set: unnamed, packs: [], keywords: [], documents: [])),
          .stickerSetNoCovered(.init(set: sticker)),
        ], unread: []))
    let sets = TrendingStickerSet.sets(in: response)
    #expect(sets.map(\.id) == [10, 11, 12, 10])
    #expect(TrendingStickerSet.sets(in: .featuredStickersNotModified(.init(count: 4))).isEmpty)
  }
  @Test func traversalKeepsFirstOccurrenceAndContinuesShortPages() async throws {
    let pages = FeaturedPages()
    let source = TrendingStickerSource(
      pageSize: 100, maximumOlderSets: 2_000,
      featured: { FeaturedPages.page([1, 2]) }, emoji: { FeaturedPages.page([2, 3]) },
      older: { try await pages.fetch($0, $1) })
    #expect(try await source.trendingSets().map(\.id) == [1, 2, 3, 4, 5])
    #expect(await pages.offsets == [0, 1, 2])
  }

  @Test func offsetLimitBoundsUnendingPages() async throws {
    let pages = FeaturedPages()
    let source = TrendingStickerSource(
      pageSize: 100, maximumOlderSets: 1,
      featured: { FeaturedPages.page([]) }, emoji: { FeaturedPages.page([]) },
      older: { try await pages.fetch($0, $1) })
    #expect(try await source.trendingSets().map(\.id) == [3])
    #expect(await pages.offsets == [0])
  }
}

private actor FeaturedPages {
  var offsets: [Int32] = []
  func fetch(_ offset: Int32, _ limit: Int32) throws -> TL.Messages.FeaturedStickersType {
    #expect(limit == 100)
    offsets.append(offset)
    return Self.page([Int64(offset) + 3], count: 3)
  }
  static func page(_ ids: [Int64], count: Int32? = nil) -> TL.Messages.FeaturedStickersType {
    .featuredStickers(
      .init(
        hash: 0, count: count ?? Int32(ids.count),
        sets: ids.map {
          .stickerSetNoCovered(
            .init(
              set: .init(id: $0, accessHash: 1, title: "Pack", shortName: "Pack", count: 1, hash: 0)
            ))
        }, unread: []))
  }
}
