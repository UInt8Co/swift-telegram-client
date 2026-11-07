/// Independent account and channel poll deadlines. The application owns scheduling
/// the actual timer and removing channels no longer tracked.
public struct RecoverySchedule: Sendable {
  /// Next account poll deadline.
  public var account: ContinuousClock.Instant
  /// Next poll deadline for each known channel.
  public var channels: [Int64: ContinuousClock.Instant] = [:]
  private let accountInterval: Duration
  private let safetySeconds: @Sendable () -> Int

  /// Creates a schedule due immediately for the account and all unknown channels.
  /// The safety interval is drawn independently after each channel recovery. Intervals
  /// must be nonnegative; channel fallback values below one second are clamped to one.
  public init(accountInterval: Duration, now: ContinuousClock.Instant = .now,
    safetySeconds: @escaping @Sendable () -> Int) {
    precondition(accountInterval >= .zero)
    self.accountInterval = accountInterval; self.safetySeconds = safetySeconds
    account = now
  }

  /// Schedules a recovered channel. A server timeout takes precedence and is at least one
  /// second; otherwise the explicit override or injected safety interval is used.
  public mutating func recovered(_ id: Int64, timeout: Int32?, now: ContinuousClock.Instant = .now,
    safetySeconds: Int? = nil) {
    let seconds = timeout.map(Int.init) ?? safetySeconds ?? self.safetySeconds()
    channels[id] = now.advanced(by: .seconds(max(1, seconds)))
  }

  /// Advances the account deadline by its configured interval.
  public mutating func accountAdvanced(now: ContinuousClock.Instant = .now) {
    account = now.advanced(by: accountInterval)
  }

  /// Returns due or unknown channel IDs in ascending order.
  public func due(_ ids: some Sequence<Int64>, now: ContinuousClock.Instant = .now) -> [Int64] {
    ids.filter { channels[$0].map { $0 <= now } ?? true }.sorted()
  }

  /// Forgets a channel's deadline. If supplied to `due` again it is immediately due.
  public mutating func remove(_ id: Int64) { channels.removeValue(forKey: id) }
}
