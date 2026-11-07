import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// An incoming private payment, including renewals that have no pre-checkout query.
/// Currency and payload are preserved for the caller to validate, including non-XTR payments.
public struct StarsPaymentReceipt: Sendable, Equatable {
  /// The payer ID derived from the private dialog and sender.
  public var userID: Int64
  /// The original invoice payload, preserved for caller validation.
  public var payload: Data
  /// The total amount in the payment currency’s smallest units.
  public var amount: Int64
  /// The original currency code, including currencies other than XTR.
  public var currency: String
  /// The Telegram payment charge identifier.
  public var chargeID: String
  /// The provider charge identifier, preserved verbatim.
  public var providerChargeID: String
  /// Whether this payment starts a recurring subscription.
  public var recurringInit: Bool
  /// Whether this payment uses a recurring subscription.
  public var recurringUsed: Bool
  /// The optional subscription expiry reported by Telegram.
  public var subscriptionUntilDate: Date?
  /// The payment service-message ID.
  public var messageID: Int32
  /// The service-message timestamp.
  public var date: Date

  /// Projects an incoming private payment addressed to or received by `accountID`.
  /// Rejects outgoing, self, non-private and mismatched-sender contexts.
  /// Does not validate currency, payload, expiry or charge uniqueness.
  public init?(message: TL.MessageType, accountID: Int64) {
    guard case .messageService(let service) = message, !service.out,
      case .messageActionPaymentSentMe(let payment) = service.action,
      case .peerUser(let peer) = service.peerId
    else { return nil }
    // Telegram may address the dialog by its sender, omit fromId, or
    // address this account with the payer in fromId.
    let payer: Int64
    if let sender = service.fromId {
      guard case .peerUser(let user) = sender,
        peer.userId == accountID || peer.userId == user.userId
      else { return nil }
      payer = user.userId
    } else {
      payer = peer.userId
    }
    guard payer != accountID else { return nil }
    userID = payer
    payload = payment.payload
    amount = payment.totalAmount
    currency = payment.currency
    chargeID = payment.charge.id
    providerChargeID = payment.charge.providerChargeId
    recurringInit = payment.recurringInit
    recurringUsed = payment.recurringUsed
    subscriptionUntilDate = payment.subscriptionUntilDate.map {
      Date(timeIntervalSince1970: Double($0))
    }
    messageID = service.id
    date = Date(timeIntervalSince1970: Double(service.date))
  }
}
