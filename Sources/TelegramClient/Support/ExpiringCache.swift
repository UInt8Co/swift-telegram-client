/// Short-lived answers, such as membership checks, shared by concurrent
/// callers. One lookup per key is in flight at a time, and an invalidation
/// made while it is in flight keeps its answer from being stored. Failures
/// are never cached. Past `capacity` entries, expired ones are dropped.
///
/// ```swift
/// let membership = ExpiringCache<Int64, Bool>(lifetime: .seconds(60))
/// let isMember = try await membership.value(for: userID) {
///   try await fetchMembership(userID)
/// }
/// ```
public actor ExpiringCache<Key: Hashable & Sendable, Value: Sendable> {
  private enum Entry {
    case loading(Task<Value, any Error>, generation: Int)
    case ready(Value, expiresAt: ContinuousClock.Instant)
  }
  private let lifetime: Duration
  private let capacity: Int
  private var entries: [Key: Entry] = [:]
  private var generation = 0

  public init(lifetime: Duration, capacity: Int = 10_000) {
    self.lifetime = lifetime
    self.capacity = capacity
  }

  /// The stored answer for `key` while it is fresh; otherwise `load`'s, which
  /// every caller asking for `key` meanwhile shares.
  public func value(for key: Key, load: @escaping @Sendable () async throws -> Value) async throws
    -> Value
  {
    switch entries[key] {
    case .ready(let value, let expiresAt) where expiresAt > .now: return value
    case .loading(let task, _): return try await task.value
    default: break
    }
    generation += 1
    let token = generation
    let task = Task { try await load() }
    entries[key] = .loading(task, generation: token)
    do {
      let value = try await task.value
      if case .loading(_, let current) = entries[key], current == token {
        if entries.count > capacity { removeExpired() }
        entries[key] = .ready(value, expiresAt: .now.advanced(by: lifetime))
      }
      return value
    } catch {
      if case .loading(_, let current) = entries[key], current == token { entries[key] = nil }
      throw error
    }
  }

  public func invalidate(_ key: Key) { entries[key] = nil }

  /// Drops a stored answer unless `keep` accepts it. A lookup still in
  /// flight is always dropped: it may have been answered before the change.
  public func invalidate(_ key: Key, unless keep: @Sendable (Value) -> Bool) {
    if case .ready(let value, _) = entries[key], keep(value) { return }
    entries[key] = nil
  }

  /// Drops the entries `predicate` selects; it sees nil for a lookup in flight.
  public func invalidate(where predicate: @Sendable (Key, Value?) -> Bool) {
    for (key, entry) in entries {
      let value: Value? = if case .ready(let value, _) = entry { value } else { nil }
      if predicate(key, value) { entries[key] = nil }
    }
  }

  private func removeExpired() {
    let now = ContinuousClock.now
    entries = entries.filter { _, entry in
      if case .ready(_, let expiresAt) = entry { return expiresAt > now }
      return true
    }
    if entries.count > capacity { entries.removeAll(keepingCapacity: true) }
  }
}
