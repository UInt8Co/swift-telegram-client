import MTProtoClientKit
import TelegramSchema

/// Exact-ID reads cover surviving messages by creation date. They cannot
/// reconstruct deleted messages, intermediate edits or participant updates.
public enum ChannelBackfill {
  /// Coverage of successfully handled exact-ID pages, not a reconstruction of all events.
  public struct Coverage: Sendable, Equatable {
    /// Number of delivered updates.
    public var messages = 0
    /// Number of successfully handled pages.
    public var pages = 0
    /// Encountered a message created before the cutoff.
    public var reachedCutoff = false
    /// Reached message ID one, or an empty channel.
    public var reachedStart = false
    /// Read every ID above a known floor, up to the snapshot's top ID.
    public var reachedFloor = false
    /// Retained messages at or below the floor re-read for offline edits.
    public var rechecked = 0
    /// Creates a coverage report; only set boundaries actually verified by the reader.
    public init(messages: Int = 0, pages: Int = 0, reachedCutoff: Bool = false,
      reachedStart: Bool = false, reachedFloor: Bool = false, rechecked: Int = 0) {
      self.messages = messages; self.pages = pages; self.reachedCutoff = reachedCutoff
      self.reachedStart = reachedStart; self.reachedFloor = reachedFloor; self.rechecked = rechecked
    }
  }

  /// The floor to read above, or nil to walk back to the creation cutoff.
  /// An initial snapshot is capped by the caller-selected ID count (negative means zero).
  /// Otherwise the supplied retained ID is returned unchanged. Callers must establish
  /// that work at or below their chosen floor has already been handled.
  public static func floor(topID: Int32, initialSnapshot: Bool, newestRetainedID: Int32?, initialMessageLimit: Int32) -> Int32? {
    guard initialSnapshot else { return newestRetainedID }
    return max(0, Int32(clamping: Int64(topID) - Int64(max(0, initialMessageLimit))), newestRetainedID ?? 0)
  }

  /// Reads oldest first above a floor, or newest pages first until the creation cutoff.
  /// Pages contain at most 100 IDs. Empty pages do not stop traversal. Recent edits
  /// on the boundary page are included.
  /// Flood waits retry the current page; cancellation and other failures escape. Callbacks
  /// must cooperate with cancellation. IDs at the Int32 boundaries do not overflow.
  public static func read(topID: Int32, cutoff: Int32, floorID: Int32? = nil,
          fetch: @Sendable (ClosedRange<Int32>) async throws -> ChannelHistoryPage,
          handle: @Sendable (ChannelHistoryPage) async throws -> Void,
          sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
          jitter: @Sendable (Duration) -> Duration = { FloodJitter.wait(for: $0) }) async throws -> Coverage {
    var coverage = Coverage()
    func pageFetch(_ ids: ClosedRange<Int32>) async throws -> ChannelHistoryPage {
      try await fetchWaitingOutFloods(ids, fetch: fetch, sleep: sleep, jitter: jitter)
    }
    if let floorID {
      // Oldest first: an interrupted read leaves the newest retained
      // message as a correct floor for the retry.
      var start = max(1, Int64(floorID) + 1)
      while start <= Int64(topID) {
        let end = min(Int64(topID), start + 99)
        var page = try await pageFetch(Int32(start)...Int32(end))
        page.updates = recent(page.updates, cutoff: cutoff, coverage: &coverage)
        try await handle(page)
        coverage.pages += 1
        coverage.messages += page.updates.count
        start = end + 1
      }
      coverage.reachedFloor = true
      return coverage
    }
    var end = topID
    while end > 0 {
      let start = max(1, end - 99)
      var page = try await pageFetch(start...end)
      page.updates = recent(page.updates, cutoff: cutoff, coverage: &coverage)
      try await handle(page)
      coverage.pages += 1
      coverage.messages += page.updates.count
      coverage.reachedStart = start == 1
      if coverage.reachedCutoff || coverage.reachedStart { return coverage }
      end = start - 1
    }
    coverage.reachedStart = true // Empty channel, top ID zero.
    return coverage
  }

  /// Re-reads up to `limit` IDs in supplied order, in batches of 100. Nonpositive limits
  /// read nothing. Returns surviving updates delivered after cutoff filtering. Flood waits
  /// retry only the current page; other failures escape without replaying prior pages.
  public static func recheck(ids: [Int32], cutoff: Int32, limit: Int,
            fetch: @Sendable ([Int32]) async throws -> ChannelHistoryPage,
            handle: @Sendable (ChannelHistoryPage) async throws -> Void,
            sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            jitter: @Sendable (Duration) -> Duration = { FloodJitter.wait(for: $0) }) async throws -> Int {
    var unused = Coverage(), count = 0
    let ids = Array(ids.prefix(max(0, limit)))
    for start in stride(from: 0, to: ids.count, by: 100) {
      let batch = Array(ids[start..<min(ids.count, start + 100)])
      var page = try await fetchWaitingOutFloods(batch, fetch: fetch, sleep: sleep, jitter: jitter)
      page.updates = recent(page.updates, cutoff: cutoff, coverage: &unused)
      try await handle(page)
      count += page.updates.count
    }
    return count
  }

  private static func recent(_ updates: [TL.UpdateType], cutoff: Int32, coverage: inout Coverage) -> [TL.UpdateType] {
    updates.filter { update in
      guard case .updateNewChannelMessage(let value) = update else { return true }
      switch value.message {
      case .message(let message):
        if message.date < cutoff { coverage.reachedCutoff = true }
        // Keep a recent edit encountered on the boundary page too.
        return max(message.date, message.editDate ?? message.date) >= cutoff
      case .messageService(let message):
        if message.date < cutoff { coverage.reachedCutoff = true; return false }
        return true
      case .messageEmpty: return false
      }
    }
  }

  /// A flood wait pauses this channel's backfill at the current page. Failing
  /// the job instead restarts the walk from the top ID, re-reads every page
  /// already handled and re-triggers the same account-wide flood forever.
  private static func fetchWaitingOutFloods<IDs>(_ ids: IDs,
                         fetch: @Sendable (IDs) async throws -> ChannelHistoryPage,
                         sleep: @Sendable (Duration) async throws -> Void,
                         jitter: @Sendable (Duration) -> Duration) async throws -> ChannelHistoryPage {
    while true {
      do {
        try Task.checkCancellation()
        return try await fetch(ids)
      } catch {
        guard !(error is CancellationError), let wait = MTProtoDirective(error)?.wait else { throw error }
        try await sleep(jitter(wait))
      }
    }
  }
}
