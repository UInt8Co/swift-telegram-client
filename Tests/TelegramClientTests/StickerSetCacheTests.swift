#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramSchema
import Testing
import TelegramClient

@Suite struct StickerSetCacheTests {
  private actor Fetcher {
    var calls = 0
    var missing = false
    var fail = false
    func configure(missing: Bool = false, fail: Bool = false) { self.missing = missing; self.fail = fail }
    func fetch(_ reference: TL.InputStickerSetType) throws -> TL.StickerSet? {
      calls += 1
      if fail { throw CancellationError() }
      return missing ? nil : testStickerSet(title: "Title \(calls)")
    }
  }

  @Test func cachedPackNamesRefreshAfterExpiry() async throws {
    let fetcher = Fetcher()
    let cache = StickerSetCache { try await fetcher.fetch($0) }
    let reference = TL.InputStickerSetType.inputStickerSetID(.init(id: 500, accessHash: 600))
    let now = Date()
    #expect(try await cache.value(for: reference, now: now)?.title == "Title 1")
    #expect(try await cache.value(for: reference, now: now.addingTimeInterval(299))?.title == "Title 1")
    #expect(try await cache.value(for: reference, now: now.addingTimeInterval(300))?.title == "Title 2")
    #expect(await fetcher.calls == 2)
  }

  @Test func unavailablePacksExpireAndTransientErrorsAreNotCached() async throws {
    let fetcher = Fetcher()
    let cache = StickerSetCache { try await fetcher.fetch($0) }
    let reference = TL.InputStickerSetType.inputStickerSetShortName(.init(shortName: "Pack"))
    let now = Date()
    await fetcher.configure(fail: true)
    await #expect(throws: CancellationError.self) { try await cache.value(for: reference, now: now) }
    await fetcher.configure(missing: true)
    #expect(try await cache.value(for: reference, now: now) == nil)
    #expect(try await cache.value(for: .inputStickerSetShortName(.init(shortName: "PACK")), now: now) == nil)
    #expect(await fetcher.calls == 2)
    await fetcher.configure()
    #expect(try await cache.value(for: reference, now: now.addingTimeInterval(301)) != nil)
    #expect(try await cache.value(for: .inputStickerSetEmpty(.init()), now: now) == nil)
    #expect(await fetcher.calls == 3)
  }

  @Test func packsLookedUpByShortNameCanBeRenderedByIDWithoutAnAccessHash() async throws {
    let fetcher = Fetcher()
    let cache = StickerSetCache { try await fetcher.fetch($0) }
    let now = Date()
    let pack = try #require(try await cache.value(for: .inputStickerSetShortName(.init(shortName: "Pack")), now: now))
    #expect(try await cache.value(for: .inputStickerSetID(.init(id: pack.id, accessHash: 0)), now: now) == pack)
    #expect(await fetcher.calls == 1)
  }
}

private func testStickerSet(id: Int64 = 500, title: String = "Sticker pack", shortName: String = "StickerPack") -> TL.StickerSet {
  .init(id: id, accessHash: 600, title: title, shortName: shortName, count: 2, hash: 1)
}
