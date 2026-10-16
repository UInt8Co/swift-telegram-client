import MTProtoClientKit

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
///
/// Telegram states its limit over two spans at once: a sustained rate per
/// minute, and a short burst of a few messages a second that a bot exceeds
/// long before the minute's budget is spent. Each ``Limit`` is one rolling
/// window; a send waits until every window has room. A flood wait that is
/// raised anyway ``hold(account:chat:for:)``s the chat, so every other writer
/// to it waits it out too instead of earning a longer one.
public actor TelegramSendRate {
  /// At most ``count`` writes within any rolling ``window``.
  public struct Limit: Equatable, Sendable {
    public var count: Int
    public var window: Duration

    public init(_ count: Int, per window: Duration) {
      self.count = max(1, count)
      self.window = window
    }

    /// One rolling minute, the window Telegram's own per-chat limit is stated in.
    public static func perMinute(_ count: Int) -> Limit { .init(count, per: TelegramSendRate.window) }
  }

  /// One rolling minute, the window Telegram's own per-chat limit is stated in.
  static let window: Duration = .seconds(60)

  private let limits: [Limit]
  private let retention: Duration
  private var recent: [Key: [Duration]] = [:]
  private var holds: [Key: Duration] = [:]
  private let now: @Sendable () -> Duration
  private let sleep: @Sendable (Duration) async throws -> Void

  private struct Key: Hashable {
    var accountID: Int64
    var chatID: Int64
  }

  public init(perMinute: Int) {
    self.init(limits: [.perMinute(perMinute)])
  }

  public init(limits: [Limit]) {
    let clock = ContinuousClock()
    let start = clock.now
    self.init(limits: limits, now: { clock.now - start }, sleep: { try await Task.sleep(for: $0) })
  }

  /// `now` is a monotonic offset and `sleep` serves a wait, both injected so a
  /// schedule can be observed without serving it.
  init(
    limits: [Limit], now: @escaping @Sendable () -> Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.limits = limits.isEmpty ? [.perMinute(20)] : limits
    retention = self.limits.map(\.window).max() ?? Self.window
    self.now = now
    self.sleep = sleep
  }

  /// Waits until `account` may write to `chat` again, then books the slot. The
  /// caller decides what waiting blocks: serialize sends per chat and a wait
  /// delays only that chat.
  ///
  /// `cost` is how many writes the call counts as, for one request that posts
  /// several messages at once. A cost above a limit's count waits for that
  /// window to empty and then books it whole.
  public func reserve(
    account accountID: Int64, chat chatID: Int64, cost: Int = 1, label: String,
    log: TelegramLog = .silent
  ) async throws {
    let key = Key(accountID: accountID, chatID: chatID)
    let cost = max(1, cost)
    while true {
      let current = now()
      if let until = holds[key] {
        if until > current {
          log.debug("\(label): writes to \(chatID) are held; waiting \(until - current)")
          try await sleep(until - current)
          continue
        }
        holds[key] = nil
      }
      let slots = (recent[key] ?? []).filter { current - $0 < retention }
      var wait = Duration.zero
      for limit in limits {
        let inWindow = slots.filter { current - $0 < limit.window }
        let excess = inWindow.count - max(0, limit.count - cost)
        guard excess > 0 else { continue }
        // Slots are booked in time order, so the window has room once its
        // `excess` oldest slots have aged out of it.
        wait = max(wait, limit.window - (current - inWindow[excess - 1]))
      }
      guard wait > .zero else {
        recent[key] = slots + Array(repeating: current, count: cost)
        return
      }
      recent[key] = slots
      log.debug(
        "\(label): account \(accountID) has written to \(chatID) \(slots.count) time(s) recently; "
          + "waiting \(wait)")
      try await sleep(wait)
    }
  }

  /// Stops `account` writing to `chat` for `duration` from now, as a flood wait
  /// instructs. A shorter hold never ends an existing longer one early.
  public func hold(account accountID: Int64, chat chatID: Int64, for duration: Duration) {
    let key = Key(accountID: accountID, chatID: chatID)
    let until = now() + duration
    holds[key] = max(holds[key] ?? until, until)
  }

  /// How much longer writes from `account` to `chat` are held, or `nil` when
  /// they are not: a caller with optional work can skip it rather than wait.
  public func remainingHold(account accountID: Int64, chat chatID: Int64) -> Duration? {
    let key = Key(accountID: accountID, chatID: chatID)
    guard let until = holds[key] else { return nil }
    let left = until - now()
    guard left > .zero else {
      holds[key] = nil
      return nil
    }
    return left
  }

  /// Books a slot, then runs `body` on the caller's actor. A flood wait it
  /// raises holds the chat; one no longer than `longestWait` is then served in
  /// place and `body` runs again, so `body` must be safe to repeat — a send
  /// with a fixed `random_id` is. A longer wait is rethrown for the caller to
  /// schedule, and the hold keeps every other writer to the chat off it
  /// meanwhile.
  public nonisolated(nonsending) func send<T>(
    account accountID: Int64, chat chatID: Int64, cost: Int = 1, label: String,
    longestWait: Duration = .seconds(10), log: TelegramLog = .silent,
    _ body: nonisolated(nonsending) () async throws -> T
  ) async throws -> T {
    while true {
      try await reserve(account: accountID, chat: chatID, cost: cost, label: label, log: log)
      do {
        return try await body()
      } catch {
        guard let wait = MTProtoDirective(error)?.wait else { throw error }
        await hold(account: accountID, chat: chatID, for: wait)
        guard wait <= longestWait else { throw error }
        log.info("\(label): flood wait on \(chatID); waiting \(wait) and sending again")
      }
    }
  }
}
