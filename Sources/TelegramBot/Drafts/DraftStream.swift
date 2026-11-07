/// Deadlines for one growing reply. Durations use a monotonic clock.
public struct DraftStreamPolicy: Sendable, Equatable {
  /// Settle after this long without content changes.
  public var inactivity: Duration
  /// The shortest gap between draft attempts. Zero, the default, shows every
  /// change as soon as the previous draft request returns: changes made while
  /// a request is in flight collapse into one follow-up with the latest content.
  public var minimumDraftInterval: Duration
  /// Refresh an unchanged draft before Telegram's ephemeral preview expires.
  public var keepAlive: Duration
  /// Settle even when content keeps changing.
  public var maximumLifetime: Duration

  /// Inactivity and lifetime may be zero to settle immediately, and the draft
  /// interval zero to draft in real time. Keep-alive must be positive.
  public init(
    inactivity: Duration = .seconds(20), minimumDraftInterval: Duration = .zero,
    keepAlive: Duration = .seconds(20), maximumLifetime: Duration = .seconds(120)
  ) {
    self.inactivity = inactivity
    self.minimumDraftInterval = minimumDraftInterval
    self.keepAlive = keepAlive
    self.maximumLifetime = maximumLifetime
  }
}

/// Why a draft must become a persistent message.
public enum DraftSettleReason: Sendable, Equatable {
  /// No content changed within the inactivity interval.
  case inactivity
  /// The generation reached its maximum lifetime.
  case lifetime
  /// The owner or user requested settlement.
  case stopped
  /// The transport cannot fit more content in this generation.
  case full
}

/// The next action, with deadlines measured from the caller's monotonic epoch.
public enum DraftStreamStep: Sendable, Equatable {
  /// Attempt to show the latest content as a draft.
  case showDraft
  /// Attempt persistence for the supplied reason.
  case settle(DraftSettleReason)
  /// Wait until this elapsed monotonic deadline.
  case wait(until: Duration)
  /// No stream is open.
  case idle
}

/// Pure scheduling state for one reply. The owner supplies monotonic elapsed
/// times and keeps the content. Consuming `next(at:)` records a draft attempt,
/// even if sending fails, so retries still respect the minimum interval.
public struct DraftStream: Sendable {
  /// The immutable timing policy used by this stream.
  public let policy: DraftStreamPolicy
  private var openedAt: Duration?
  private var changedAt: Duration?
  private var draftedAt: Duration?
  private var dirty = false
  private var reason: DraftSettleReason?

  /// Creates an idle stream with the supplied timing policy.
  public init(policy: DraftStreamPolicy = .init()) {
    precondition(policy.inactivity >= .zero && policy.maximumLifetime >= .zero)
    precondition(policy.minimumDraftInterval >= .zero && policy.keepAlive > .zero)
    self.policy = policy
  }

  /// Whether the stream has crossed its settlement boundary. Further changes
  /// belong to a fresh stream, after the owner finishes this one.
  public var isClosing: Bool { reason != nil }

  /// Opens an idle stream or records new content in an open one.
  public mutating func changed(at now: Duration) {
    guard !isClosing else { return }
    if openedAt == nil { openedAt = now }
    changedAt = now
    dirty = true
  }

  /// Requests immediate settlement; the first explicit reason wins.
  public mutating func stopped(at now: Duration) { close(.stopped) }

  /// Requests settlement because the owner cannot fit more content.
  public mutating func full(at now: Duration) { close(.full) }

  /// Returns to idle after the owner has attempted persistence.
  public mutating func settled(at now: Duration) {
    openedAt = nil
    changedAt = nil
    draftedAt = nil
    reason = nil
    dirty = false
  }

  /// Consumes the next action. Settlement repeats until `settled(at:)`;
  /// expiry takes precedence over drafts, and lifetime wins equal deadlines.
  public mutating func next(at now: Duration) -> DraftStreamStep {
    guard let openedAt, let changedAt else { return .idle }
    if let reason { return .settle(reason) }
    let inactivity = changedAt + policy.inactivity
    let lifetime = openedAt + policy.maximumLifetime
    let expiry = min(inactivity, lifetime)
    if now >= expiry {
      reason = lifetime <= inactivity ? .lifetime : .inactivity
      return .settle(reason!)
    }
    let draft =
      draftedAt.map {
        $0
          + (dirty
            ? policy.minimumDraftInterval : max(policy.minimumDraftInterval, policy.keepAlive))
      } ?? now
    if now >= draft {
      draftedAt = now
      dirty = false
      return .showDraft
    }
    return .wait(until: min(expiry, draft))
  }

  private mutating func close(_ reason: DraftSettleReason) {
    guard openedAt != nil, self.reason == nil else { return }
    self.reason = reason
  }
}
