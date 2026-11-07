import MTProtoClientKit

/// One channel attempt. A transient failure escapes immediately; the channel
/// lane retries from its last handled page without replaying another channel.
public enum ChannelRecovery {
  /// A recovered position still does not cover the pushed sequence.
  public enum Failure: Error, Sendable {
    /// Delivery must wait for additional recovery.
    case behindPush
  }

  /// Structured coverage of a too-long difference; contains no logging implementation.
  public struct Gap: Sendable {
    /// Position at the start of this recovery attempt.
    public var initialPTS: Int32
    /// Position used to fetch this snapshot.
    public var fromPTS: Int32
    /// Proposed position, committed only on success.
    public var nextPTS: Int32?
    /// Snapshot top message ID, when supplied.
    public var topID: Int32?
    /// Whether a rejected position caused a reset to one.
    public var resetAfterRejection: Bool
    /// Successfully handled backfill coverage, if available.
    public var coverage: ChannelBackfill.Coverage?
    /// Description of a permanent failure, when reported.
    public var error: String?

    /// A channel first read from 1 (newly joined, no saved position) had no
    /// earlier history to lose: its snapshot is routine. A gap after a
    /// saved or rejected position may have lost edits and deletions.
    public var initialSnapshot: Bool { initialPTS == 1 && !resetAfterRejection }
  }

  /// Recovers gaps before delivery, then commits only after delivery succeeds. Known push
  /// payloads are delivered even when recovery advances beyond them; callers must deduplicate.
  /// The `recover` callback returns the recovered channel PTS, not a polling timeout.
  /// A nil recovered position suppresses checkpoint recreation. Cancellation prevents commit.
  public static func push(_ id: Int64, position: Int32?, updates: [UpdateSequence],
          recover: @Sendable (Int32) async throws -> Int32?,
          deliver: @Sendable () async throws -> Void,
          commit: @Sendable (Int32) async throws -> Void) async throws {
    let starts = updates.compactMap { update -> Int32? in
      if case .channel(_, let pts, let count) = update, pts > 0 { return Int32(clamping: max(1, Int64(pts) - Int64(count))) }
      return nil
    }
    let initial = position ?? starts.min() ?? 1
    var positions = SequencePositions(account: .beginning, channels: [id: initial])
    let push = PushSequence(updates: updates)
    let gap = positions.advance(past: [push]).channels.contains(id)
    let mustRecover = gap || (position == nil && starts.isEmpty)
    let current = mustRecover ? try await recover(initial) : initial
    if let current {
      positions = SequencePositions(account: .beginning, channels: [id: current])
      // The difference satisfies the hint. Actual pts entries must still
      // be contiguous before a newer pushed event can reach the handler.
      let entries = updates.filter { if case .channelTooLong = $0 { return false }; return true }
      guard !positions.advance(past: [.init(updates: entries)]).channels.contains(id) else {
        throw Failure.behindPush
      }
    }
    // A too-long snapshot may omit a push already waiting in this lane.
    // Preserve its payload even when the recovered pts is further ahead;
    // consumers deduplicate payloads they already handled.
    try await deliver()
    try Task.checkCancellation()
    if current != nil, let next = positions.channels[id] { try await commit(next) }
  }

  /// The final page's polling hint after all handled pages have been committed.
  public struct ReadResult: Sendable, Equatable {
    /// Suggested delay in seconds until another read, or nil when Telegram supplies none.
    /// This is a polling timeout, never a channel PTS. Committed PTS values go to `commit`.
    public let timeout: Int32?
  }

  /// Drains differences and commits each handled page. Invalid/empty stored positions other
  /// than one reset to one; replication failures escape unchanged. Incomplete snapshots never commit.
  /// Gap reports omit cancellation and injected transient failures. Retried work may replay
  /// already delivered payloads. All callbacks must cooperate with cancellation.
  public static func read(from start: Int32, channelID: Int64,
             isTransient: @Sendable (any Error) -> Bool,
          fetch: @Sendable (Int32) async throws -> ChannelDifferenceBatch,
          handle: @Sendable (ChannelDifferenceBatch) async throws -> Void,
          backfill: @Sendable (Int32) async throws -> ChannelBackfill.Coverage,
          commit: @Sendable (Int32) async throws -> Void,
          rejected: @Sendable (Int32) async -> Void = { _ in },
          reportGap: @Sendable (Gap) async -> Void = { _ in }) async throws -> ReadResult {
    var position = start
    var resetAfterRejection = false
    while true {
      let batch: ChannelDifferenceBatch
      do { batch = try await fetch(position) }
      catch where ChannelState.rejectsStoredPTS(error) && position != 1 {
        await rejected(position)
        position = 1
        resetAfterRejection = true
        continue
      }
      var gap = Gap(initialPTS: start, fromPTS: position, nextPTS: batch.pts,
             topID: batch.topMessageID, resetAfterRejection: resetAfterRejection)
      do {
        guard let next = batch.pts else { throw ChannelDifferenceError.backfillSnapshotUnavailable(channelID) }
        if batch.skippedGap {
          guard let top = batch.topMessageID, top >= 0 else { throw ChannelDifferenceError.backfillSnapshotUnavailable(channelID) }
          try await handle(batch)
          gap.coverage = try await backfill(top)
          guard let coverage = gap.coverage,
             coverage.reachedCutoff || coverage.reachedStart || coverage.reachedFloor else {
            throw ChannelDifferenceError.backfillSnapshotUnavailable(channelID)
          }
        } else {
          try await handle(batch)
        }
        try Task.checkCancellation()
        try await commit(next)
        position = next
      } catch {
        // A retry still has the original checkpoint. Report the gap
        // once when it completes, or when coverage fails permanently.
        if batch.skippedGap, !Task.isCancelled, !(error is CancellationError),
         !isTransient(error), MTProtoDirective(error)?.wait == nil {
          gap.error = String(describing: error)
          await reportGap(gap)
        }
        throw error
      }
      if batch.skippedGap { await reportGap(gap) }
      if batch.isFinal { return ReadResult(timeout: batch.timeout) }
    }
  }
}
