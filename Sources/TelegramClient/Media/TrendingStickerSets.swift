import TelegramSchema

/// Metadata for a featured sticker or custom-emoji pack.
public struct TrendingStickerSet: Equatable, Hashable, Sendable {
  /// Numeric set identity.
  public var id: Int64
  /// Whether this is a custom-emoji set.
  public var emojis: Bool
  /// Original public short name.
  public var shortName: String
  /// Current display title.
  public var title: String

  /// Creates a featured pack summary.
  public init(id: Int64, emojis: Bool, shortName: String, title: String) {
    self.id = id
    self.emojis = emojis
    self.shortName = shortName
    self.title = title
  }

  /// Projects live set metadata, without retaining documents.
  public init(_ set: TL.StickerSet) {
    self.init(id: set.id, emojis: set.emojis, shortName: set.shortName, title: set.title)
  }

  /// Projects all covered-set variants in response order, retaining duplicates.
  public static func sets(in response: TL.Messages.FeaturedStickersType) -> [TrendingStickerSet] {
    guard case .featuredStickers(let value) = response else { return [] }
    return value.sets.map { covered in
      switch covered {
      case .stickerSetCovered(let value): .init(value.set)
      case .stickerSetMultiCovered(let value): .init(value.set)
      case .stickerSetFullCovered(let value): .init(value.set)
      case .stickerSetNoCovered(let value): .init(value.set)
      }
    }
  }
}

/// Reads featured and older featured packs without marking them read or installing them.
/// Telegram requires a user account for these methods. Errors propagate unchanged.
public struct TrendingStickerSource: Sendable {
  private let featured: @Sendable () async throws -> TL.Messages.FeaturedStickersType
  private let emoji: @Sendable () async throws -> TL.Messages.FeaturedStickersType
  private let older: @Sendable (Int32, Int32) async throws -> TL.Messages.FeaturedStickersType
  private let pageSize: Int32
  private let maximumOlderSets: Int32

  /// Creates a source using a connected user client. Limits bound the older-page traversal;
  /// a final page may cross the maximum offset. The default limits are 100 and 2,000.
  public init(api: TLClient, pageSize: Int32 = 100, maximumOlderSets: Int32 = 2_000) {
    self.init(
      pageSize: pageSize, maximumOlderSets: maximumOlderSets,
      featured: { try await api.messages.getFeaturedStickers(hash: 0) },
      emoji: { try await api.messages.getFeaturedEmojiStickers(hash: 0) },
      older: { try await api.messages.getOldFeaturedStickers(offset: $0, limit: $1, hash: 0) })
  }

  /// Creates a source with injected reads. Each closure runs in the caller task and
  /// owns RPC cancellation. Page size must be positive; the older offset limit nonnegative.
  public init(
    pageSize: Int32 = 100, maximumOlderSets: Int32 = 2_000,
    featured: @escaping @Sendable () async throws -> TL.Messages.FeaturedStickersType,
    emoji: @escaping @Sendable () async throws -> TL.Messages.FeaturedStickersType,
    older: @escaping @Sendable (Int32, Int32) async throws -> TL.Messages.FeaturedStickersType
  ) {
    precondition(pageSize > 0 && maximumOlderSets >= 0)
    self.pageSize = pageSize
    self.maximumOlderSets = maximumOlderSets
    self.featured = featured
    self.emoji = emoji
    self.older = older
  }

  /// Returns first occurrences by set ID: featured stickers, emoji, then older pages.
  /// Empty or not-modified older responses stop traversal; short pages do not by themselves.
  public func trendingSets() async throws -> [TrendingStickerSet] {
    var sets = TrendingStickerSet.sets(in: try await featured())
    sets += TrendingStickerSet.sets(in: try await emoji())
    var offset: Int32 = 0
    while offset < maximumOlderSets {
      let page = try await older(offset, pageSize)
      let found = TrendingStickerSet.sets(in: page)
      sets += found
      guard case .featuredStickers(let value) = page, !found.isEmpty,
        Int64(offset) + Int64(found.count) < Int64(value.count)
      else { break }
      offset += Int32(found.count)
    }
    var seen: Set<Int64> = []
    return sets.filter { seen.insert($0.id).inserted }
  }
}
