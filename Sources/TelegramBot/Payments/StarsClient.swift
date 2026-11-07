import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// An invoice amount or payload falls outside the supported subscription limits.
public enum StarsInvoiceError: Error, Equatable {
  /// The amount is outside 1...10_000 Stars.
  case invalidStars
  /// The payload is outside 1...128 bytes.
  case invalidPayload
}

/// Constructs native invoices for recurring 30-day Stars subscriptions.
public enum StarsInvoice {
  /// Builds a 30-day XTR subscription invoice for export as a link.
  /// `stars` must be in 1...10_000 and `payload` must contain 1...128 bytes.
  /// Throws ``StarsInvoiceError`` before constructing media when either is invalid.
  public static func subscriptionMedia(
    title: String, description: String, stars: Int, payload: Data
  ) throws -> TL.InputMediaType {
    guard (1...10_000).contains(stars) else { throw StarsInvoiceError.invalidStars }
    guard (1...128).contains(payload.count) else { throw StarsInvoiceError.invalidPayload }
    return .inputMediaInvoice(
      .init(
        title: title, description: description,
        invoice: .init(
          currency: "XTR", prices: [.init(label: title, amount: Int64(stars))],
          subscriptionPeriod: 2_592_000), payload: payload, provider: nil,
        providerData: .init(data: "{}")))
  }
}

/// Stars transport only; callers own invoice expiry, authorization and charge deduplication.
public struct StarsClient: Sendable {
  private let api: TLClient

  /// Uses the supplied API transport; transport errors and cancellation propagate.
  public init(api: TLClient) { self.api = api }

  /// Exports a recurring 30-day XTR subscription invoice as a link.
  /// Accepts 1...10_000 Stars and 1...128 payload bytes; validates before sending.
  public func exportSubscriptionInvoice(
    title: String, description: String, stars: Int, payload: Data
  ) async throws -> String {
    let media = try StarsInvoice.subscriptionMedia(
      title: title, description: description, stars: stars, payload: payload)
    return try await api.payments.exportInvoice(invoiceMedia: media).url
  }

  /// A nil error accepts the query. Telegram requires an answer within ten seconds.
  public func answerPrecheckout(queryID: Int64, errorMessage: String?) async throws {
    _ = try await api.messages.setBotPrecheckoutResults(
      success: errorMessage == nil,
      queryId: queryID, error: errorMessage)
  }

  /// Disables renewal for a charge; this does not refund the existing payment.
  public func cancelSubscription(user: TL.InputUserType, chargeID: String) async throws {
    _ = try await api.payments.botCancelStarsSubscription(
      restore: false, userId: user, chargeId: chargeID)
  }

  /// Return the updates so the caller can persist peers and process them normally.
  public func refundCharge(user: TL.InputUserType, chargeID: String) async throws -> TL.UpdatesType
  {
    try await api.payments.refundStarsCharge(userId: user, chargeId: chargeID)
  }
}
