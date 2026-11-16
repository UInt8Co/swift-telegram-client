/// Shares an exponentially increasing cooldown for unusable lists within one account.
/// It also optionally retains complete lists for protection checks that permit
/// cached membership. Fresh authorization/enforcement callers must bypass these
/// lists. Completeness failures can delay a decision but never establish absence.
/// Invalidate complete lists on participant changes. RPC failures
/// (including flood waits) and cancellation retain their caller's retry policy.
public actor ParticipantLookupCache {
  private struct Key: Hashable {
    var channelID: Int64
    var role: ChannelParticipantLookup.Role
  }
  private struct Failure {
    var error: ParticipantLookupError
    var until: ContinuousClock.Instant
    var attempts: Int
  }
  private var failures: [Key: Failure] = [:]
  private struct CompleteList {
    var members: Set<Int64>
    var until: ContinuousClock.Instant
  }
  private var completeLists: [Key: CompleteList] = [:]
  /// Capture before fetching; invalidation prevents an in-flight old list from
  /// being installed after a participant update.
  public private(set) var generation = 0

  public func membership(userID: Int64, channelID: Int64, role: ChannelParticipantLookup.Role) -> Bool? {
    let instant = now()
    completeLists = completeLists.filter { $0.value.until > instant }
    return completeLists[Key(channelID: channelID, role: role)]?.members.contains(userID)
  }

  public func recordComplete(_ members: Set<Int64>, channelID: Int64,
    role: ChannelParticipantLookup.Role, generation: Int) {
    guard generation == self.generation else { return }
    completeLists[Key(channelID: channelID, role: role)] = CompleteList(members: members, until: now().advanced(by: .seconds(60)))
  }

  public func invalidate(channelID: Int64) {
    generation &+= 1
    completeLists = completeLists.filter { $0.key.channelID != channelID }
  }

  private let duration: Duration
  private let maximumDuration: Duration
  private let now: @Sendable () -> ContinuousClock.Instant

  public init(duration: Duration = .seconds(60), maximumDuration: Duration = .seconds(3600),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
    self.duration = max(.zero, duration)
    self.maximumDuration = max(.zero, max(duration, maximumDuration))
    self.now = now
  }

  /// Calls `operation` only when this channel/role has no incomplete-list hold.
  /// This method never stores or shares the operation's Boolean across users.
  public func run(channelID: Int64, role: ChannelParticipantLookup.Role,
    operation: @Sendable () async throws -> Bool) async throws -> Bool {
    try Task.checkCancellation()
    let key = Key(channelID: channelID, role: role)
    let instant = now()
    // Retain recent attempts after expiry so permanently partial lists back off.
    failures = failures.filter { $0.value.until.advanced(by: maximumDuration) > instant }
    if let failure = failures[key], failure.until > instant { throw failure.error }
    do {
      let result = try await operation()
      failures[key] = nil
      return result
    } catch let error as ParticipantLookupError {
      try Task.checkCancellation()
      let attempts = min(6, failures[key]?.attempts ?? 0)
      let delay = min(maximumDuration, duration * (1 << attempts))
      failures[key] = Failure(error: error, until: now().advanced(by: delay), attempts: attempts + 1)
      throw error
    }
  }
}
