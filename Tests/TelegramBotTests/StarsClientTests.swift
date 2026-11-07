import TelegramBot
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

private actor StarsTransport: TLClientTransport {
  var requests: [Data] = []
  var replies: [Data]
  init(_ replies: [Data]) { self.replies = replies }
  func send(_ requestBody: Data) throws -> Data {
    requests.append(requestBody)
    guard !replies.isEmpty else { throw CancellationError() }
    return replies.removeFirst()
  }
}

@Suite struct StarsClientTests {
  @Test func exportsLinksAndRejectsInvalidInvoicesBeforeSending() async throws {
    let transport = StarsTransport([
      TL.Payments.ExportedInvoice(url: "https://t.me/$invoice").tlSerialized()
    ])
    let client = StarsClient(api: TLClient(transport: transport))
    await #expect(throws: StarsInvoiceError.invalidStars) {
      try await client.exportSubscriptionInvoice(
        title: "Title", description: "Description", stars: 0, payload: Data([1]))
    }
    #expect(await transport.requests.isEmpty)
    let payload = Data([0, 255])
    #expect(
      try await client.exportSubscriptionInvoice(
        title: "Title", description: "Description", stars: 5,
        payload: payload) == "https://t.me/$invoice")
    let request = try TL.Payments.ExportInvoice(tlData: #require(await transport.requests.first))
    #expect(
      try request.invoiceMedia
        == StarsInvoice.subscriptionMedia(
          title: "Title", description: "Description", stars: 5, payload: payload))
  }

  @Test func acceptsAndDeclinesPrecheckoutWithTheCorrectFlags() async throws {
    let transport = StarsTransport([true.tlSerialized(), true.tlSerialized()])
    let client = StarsClient(api: TLClient(transport: transport))
    try await client.answerPrecheckout(queryID: Int64.max, errorMessage: nil)
    try await client.answerPrecheckout(queryID: 2, errorMessage: "Please try again.")
    let requests = try await transport.requests.map {
      try TL.Messages.SetBotPrecheckoutResults(tlData: $0)
    }
    #expect(requests[0].queryId == Int64.max && requests[0].success && requests[0].error == nil)
    #expect(
      requests[1].queryId == 2 && !requests[1].success && requests[1].error == "Please try again.")
  }

  @Test func cancelsAutoRenewalAndReturnsRefundUpdates() async throws {
    let updates = TL.UpdatesType.updates(
      .init(updates: [], users: [.user(.init(id: 7))], chats: [], date: 1, seq: 1))
    let transport = StarsTransport([true.tlSerialized(), updates.tlSerialized()])
    let client = StarsClient(api: TLClient(transport: transport))
    let user = TL.InputUserType.inputUser(.init(userId: 7, accessHash: 123))
    try await client.cancelSubscription(user: user, chargeID: "subscription")
    #expect(try await client.refundCharge(user: user, chargeID: "duplicate") == updates)
    let requests = await transport.requests
    let cancel = try TL.Payments.BotCancelStarsSubscription(tlData: requests[0])
    #expect(!cancel.restore && cancel.userId == user && cancel.chargeId == "subscription")
    let refund = try TL.Payments.RefundStarsCharge(tlData: requests[1])
    #expect(refund.userId == user && refund.chargeId == "duplicate")
  }

  @Test func transportFailuresPropagateToTheCaller() async {
    let client = StarsClient(api: TLClient(transport: StarsTransport([])))
    await #expect(throws: CancellationError.self) {
      try await client.answerPrecheckout(queryID: 1, errorMessage: nil)
    }
  }

  @Test func invoiceIsAnXTRSubscriptionWithNoProvider() throws {
    let payload = Data(repeating: 255, count: 128)
    let media = try StarsInvoice.subscriptionMedia(
      title: "Group subscription", description: "Thirty days", stars: 10_000, payload: payload)
    guard case .inputMediaInvoice(let value) = media else {
      Issue.record("Expected invoice media")
      return
    }
    #expect(value.title == "Group subscription" && value.description == "Thirty days")
    #expect(value.invoice.currency == "XTR" && value.invoice.subscriptionPeriod == 2_592_000)
    #expect(value.invoice.prices == [.init(label: "Group subscription", amount: 10_000)])
    #expect(value.provider == nil && value.providerData.data == "{}" && value.payload == payload)
    #expect(try TL.InputMediaType(tlData: media.tlSerialized()) == media)
  }

  @Test func invalidInvoiceAmountsAndPayloadsAreRejected() throws {
    for stars in [-1, 0, 10_001, Int.max] {
      #expect(throws: StarsInvoiceError.invalidStars) {
        try StarsInvoice.subscriptionMedia(
          title: "t", description: "d", stars: stars, payload: Data([1]))
      }
    }
    for payload in [Data(), Data(repeating: 0, count: 129)] {
      #expect(throws: StarsInvoiceError.invalidPayload) {
        try StarsInvoice.subscriptionMedia(title: "t", description: "d", stars: 1, payload: payload)
      }
    }
    _ = try StarsInvoice.subscriptionMedia(
      title: "t", description: "d", stars: 1, payload: Data([1]))
  }

}
