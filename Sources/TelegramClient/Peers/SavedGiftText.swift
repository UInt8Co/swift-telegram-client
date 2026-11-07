import TelegramSchema

/// A message attached to a saved gift, preserving its TL entities and original gift.
public struct SavedGiftText: Sendable {
  /// The field containing this message.
  public enum Origin: Sendable {
    /// The saved gift's outer message.
    case message
    /// A unique gift's original-details attribute message.
    case originalDetails
  }
  /// The gift containing the message; callers can derive their own stable identity.
  public let gift: TL.SavedStarGift
  /// The message's position within the gift.
  public let origin: Origin
  /// The disclosed sender, or nil when absent or the gift's name is hidden.
  public let author: PeerID?
  /// Original text and entities, including empty text when explicitly present.
  public let text: TL.TextWithEntities

  /// Projects outer messages followed by original-details messages in page/attribute order.
  /// The optional nonnegative limit bounds input gifts before filtering, not output texts;
  /// nonpositive limits select nothing. By default all gifts, including unsaved ones, qualify.
  /// The predicate is synchronous and called once per selected gift. No I/O is performed.
  public static func project(_ page: TL.Payments.SavedStarGifts, limit: Int? = nil,
    including predicate: (TL.SavedStarGift) -> Bool = { _ in true }) -> [SavedGiftText] {
    var result: [SavedGiftText] = []
    for gift in page.gifts.prefix(max(0, limit ?? page.gifts.count)) where predicate(gift) {
      if let text = gift.message {
        result.append(.init(gift: gift, origin: .message,
          author: gift.nameHidden ? nil : gift.fromId.map(PeerID.init), text: text))
      }
      if case .starGiftUnique(let unique) = gift.gift {
        for case .starGiftAttributeOriginalDetails(let original) in unique.attributes {
          if let text = original.message {
            result.append(.init(gift: gift, origin: .originalDetails,
              author: gift.nameHidden ? nil : original.senderId.map(PeerID.init), text: text))
          }
        }
      }
    }
    return result
  }
}
