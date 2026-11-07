import TelegramSchema
import TelegramClient
import Testing

@Suite struct SavedGiftTextTests {
  private func gift(hidden: Bool = false, unsaved: Bool = false) -> TL.SavedStarGift {
    .init(nameHidden: hidden, unsaved: unsaved, fromId: .peerUser(.init(userId: 7)), date: 1,
      gift: .starGiftUnique(.init(id: 88, giftId: 90, title: "Catalog", slug: "catalog", num: 1,
        attributes: [.starGiftAttributeOriginalDetails(.init(senderId: .peerUser(.init(userId: 8)),
          recipientId: .peerUser(.init(userId: 9)), date: 1, message: .init(text: "Original", entities: [])))],
        availabilityIssued: 1, availabilityTotal: 1)), message: .init(text: "", entities: []))
  }
  @Test func preservesMessagesAndOriginalDetailsWithHiddenAttribution() {
    let first = gift(), hidden = gift(hidden: true)
    let page = TL.Payments.SavedStarGifts(count: 2, gifts: [first, hidden], chats: [], users: [])
    let projected = SavedGiftText.project(page)
    #expect(projected.map(\.text.text) == ["", "Original", "", "Original"])
    #expect(projected.map(\.origin) == [.message, .originalDetails, .message, .originalDetails])
    #expect(projected.map(\.author) == [.init(kind: .user, id: 7), .init(kind: .user, id: 8), nil, nil])
    #expect(projected.first?.gift == first)
  }
  @Test func limitsInputsBeforeCallerFiltering() {
    let page = TL.Payments.SavedStarGifts(count: 2, gifts: [gift(unsaved: true), gift()], chats: [], users: [])
    #expect(SavedGiftText.project(page).count == 4)
    #expect(SavedGiftText.project(page, including: { !$0.unsaved }).count == 2)
    #expect(SavedGiftText.project(page, limit: 1, including: { !$0.unsaved }).isEmpty)
    #expect(SavedGiftText.project(page, limit: -1).isEmpty)
  }
}
