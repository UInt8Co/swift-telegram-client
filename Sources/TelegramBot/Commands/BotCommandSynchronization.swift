#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A caller-isolated coalescing scheduler for command publication sweeps.
/// New requests during an active sweep are retained for the next sweep.
public struct BotCommandSynchronization<Key: Hashable & Sendable>: Sendable {
  private let refreshInterval: TimeInterval
  private let progressDelay: TimeInterval
  private let failureDelays: [TimeInterval]

  /// Creates a scheduler with positive finite refresh and nonnegative finite retry delays.
  /// Failure delays must be nonempty; consecutive failures saturate at the last delay.
  public init(refreshInterval: TimeInterval, progressDelay: TimeInterval, failureDelays: [TimeInterval]) {
    precondition(refreshInterval.isFinite && refreshInterval > 0)
    precondition(progressDelay.isFinite && progressDelay >= 0)
    precondition(!failureDelays.isEmpty && failureDelays.allSatisfy { $0.isFinite && $0 >= 0 })
    self.refreshInterval = refreshInterval
    self.progressDelay = progressDelay
    self.failureDelays = failureDelays
  }

  private var groups: [Key]?
  private var migrations: [Key: Key] = [:]
  private var pending = false
  private var running = false
  private var signature: String?
  private var refreshAfter = Date.distantPast
  private var retryAfter: Date?
  private var failures = 0
  /// Revision advanced by explicit or periodic refreshes, for caller-owned prerequisite caches.
  public private(set) var revision = 0

  /// Records the latest keys and signature; returns added and removed keys.
  /// Periodic refresh and due retries become pending only when this method is called.
  @discardableResult
  public mutating func request(groups: [Key], signature: String, now: Date = Date()) -> Set<Key> {
    let normalized: [Key] = groups.reduce(into: []) { result, group in
      let group = migrations[group] ?? group
      if !result.contains(group) { result.append(group) }
    }
    let changed = Set(self.groups ?? []).symmetricDifference(normalized)
    if !changed.isEmpty || self.groups == nil || self.signature != signature {
      pending = true
    }
    self.groups = normalized
    self.signature = signature
    if now >= refreshAfter {
      revision += 1
      pending = true
      refreshAfter = now.addingTimeInterval(refreshInterval)
    }
    if let retryAfter, now >= retryAfter {
      pending = true
      self.retryAfter = nil
    }
    return changed
  }

  /// Requests a refresh and advances the caller's cached-prerequisite revision.
  public mutating func refresh() {
    revision += 1
    pending = true
  }

  /// Requests work without invalidating cached prerequisites.
  public mutating func invalidate() { pending = true }

  /// Remaps a key and requests work. The supplied strict order stabilizes the normalized registry.
  public mutating func migrate(from old: Key, to new: Key, orderedBefore: (Key, Key) -> Bool) {
    migrations[old] = new
    if let groups {
      self.groups = Array(Set(groups.map { $0 == old ? new : $0 })).sorted(by: orderedBefore)
    }
    pending = true
  }

  /// Starts one pending sweep, preserving registry order; nil means none is ready or one is running.
  /// Every successful begin must be paired with finish, including on cancellation or failure.
  public mutating func begin() -> [Key]? {
    guard pending, !running, let groups else { return nil }
    pending = false
    running = true
    return groups
  }

  /// Ends the active sweep and schedules remaining work. Concurrent invalidations remain pending.
  /// This value type performs no sleeps, RPCs or cancellation checks; its owner serializes access.
  public mutating func finish(remaining: Bool = false, madeProgress: Bool = false, now: Date = Date()) {
    running = false
    if remaining {
      failures = madeProgress ? 0 : min(failures + 1, failureDelays.count)
      let delay = madeProgress ? progressDelay : failureDelays[failures - 1]
      retryAfter = now.addingTimeInterval(delay)
    } else {
      failures = 0
      retryAfter = nil
    }
  }

}
