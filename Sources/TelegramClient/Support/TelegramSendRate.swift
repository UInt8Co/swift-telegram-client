/// Paces everything an account sends.
///
/// Telegram limits how fast one account may write to one chat, and answers one
/// that goes faster with a flood wait that grows the longer it keeps trying.
/// Serving those where they are raised (``FloodWait``) is the floor, not the
/// plan: a burst would spend the whole budget in seconds and then crawl under
/// waits, delaying every later message behind it. Holding to a rate below
/// Telegram's own never earns the wait in the first place.
///
/// The budget is per **account and chat**, because that is what the limit is
/// stated over. It applies to every send, edit and delete, since Telegram does
/// not distinguish a backfill from live traffic either.
public actor TelegramSendRate {
  /// One rolling minute, the window Telegram's own per-chat limit is stated in.
  static let window: Duration = .seconds(60)

  private let perMinute: Int
  private var recent: [Key: [ContinuousClock.Instant]] = [:]
  private let clock = ContinuousClock()

  public init(perMinute: Int) {
    self.perMinute = max(1, perMinute)
  }

  private struct Key: Hashable {
    var accountID: Int64
    var chatID: Int64
  }

  /// Waits until `account` may write to `chat` again, then books the slot. The
  /// caller decides what waiting blocks: serialize sends per chat and a wait
  /// delays only that chat.
  public func reserve(
    account accountID: Int64, chat chatID: Int64, label: String, log: TelegramLog = .silent
  ) async throws {
    let key = Key(accountID: accountID, chatID: chatID)
    while true {
      let now = clock.now
      var slots = (recent[key] ?? []).filter { now - $0 < Self.window }
      guard slots.count >= perMinute, let oldest = slots.first else {
        slots.append(now)
        recent[key] = slots
        return
      }
      recent[key] = slots
      let wait = Self.window - (now - oldest)
      log.debug(
        "\(label): account \(accountID) has sent \(slots.count) message(s) to \(chatID) in the "
          + "last minute; waiting \(wait)")
      try await Task.sleep(for: wait)
    }
  }
}
