import TelegramBot
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct StarsPaymentReceiptTests {
  private func payment(
    peer: TL.PeerType, sender: TL.PeerType? = nil, out: Bool = false,
    renewal: Bool = false, currency: String = "XTR", expiry: Int32? = 2_592_100
  ) -> TL.MessageType {
    .messageService(
      .init(
        out: out, id: 25, fromId: sender, peerId: peer, date: 100,
        action: .messageActionPaymentSentMe(
          .init(
            recurringInit: !renewal, recurringUsed: renewal,
            currency: currency, totalAmount: Int64.max, payload: Data([0, 255, 127]),
            charge: .init(id: "telegram-charge", providerChargeId: "provider-charge"),
            subscriptionUntilDate: expiry))))
  }

  @Test(arguments: [false, true])
  func decodesInitialAndRenewalReceiptsInBothPrivateAddressForms(renewal: Bool) throws {
    for (peer, sender) in [(Int64(7), Optional<Int64>.none), (7, 7), (99, 7)] {
      let message = payment(
        peer: .peerUser(.init(userId: peer)),
        sender: sender.map { .peerUser(.init(userId: $0)) }, renewal: renewal)
      let receipt = try #require(
        StarsPaymentReceipt(message: TL.MessageType(tlData: message.tlSerialized()), accountID: 99))
      #expect(receipt.userID == 7 && receipt.messageID == 25)
      #expect(
        receipt.payload == Data([0, 255, 127]) && receipt.amount == Int64.max
          && receipt.currency == "XTR")
      #expect(
        receipt.chargeID == "telegram-charge" && receipt.providerChargeID == "provider-charge")
      #expect(receipt.recurringInit == !renewal && receipt.recurringUsed == renewal)
      #expect(receipt.subscriptionUntilDate == Date(timeIntervalSince1970: 2_592_100))
      #expect(receipt.date == Date(timeIntervalSince1970: 100))
    }
  }

  @Test func preservesOtherCurrenciesAndMissingExpiryForCallerValidation() throws {
    let receipt = try #require(
      StarsPaymentReceipt(
        message: payment(
          peer: .peerUser(.init(userId: 7)),
          currency: "USD", expiry: nil), accountID: 99))
    #expect(receipt.currency == "USD" && receipt.subscriptionUntilDate == nil)
  }

  @Test func rejectsGroupOutgoingSelfAndMismatchedSenderContexts() {
    let payer = TL.PeerType.peerUser(.init(userId: 7))
    let messages = [
      payment(peer: .peerChat(.init(chatId: 1)), sender: payer),
      payment(peer: .peerChannel(.init(channelId: 1)), sender: payer),
      payment(peer: payer, out: true),
      payment(peer: .peerUser(.init(userId: 99))),
      payment(peer: payer, sender: .peerUser(.init(userId: 8))),
      payment(peer: payer, sender: .peerChannel(.init(channelId: 1))),
      TL.MessageType.message(.init(id: 1, peerId: payer, date: 0, message: "/pay")),
      .messageService(.init(id: 1, peerId: payer, date: 0, action: .messageActionEmpty(.init()))),
    ]
    for message in messages { #expect(StarsPaymentReceipt(message: message, accountID: 99) == nil) }
  }
}
