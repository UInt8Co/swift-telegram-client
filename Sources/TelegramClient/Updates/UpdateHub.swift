import TelegramSchema

/// Wakes a reader when a channel it watches changes.
///
/// Telegram pushes a channel's updates — or `updateChannelTooLong` when it will
/// not — instead of replaying them, so a hint is all a reader needs before it
/// drains that channel's difference. Waiting on a hint rather than polling is
/// what keeps an idle client idle.
public actor UpdateHub {
  private var revisions: [Int64: UInt64] = [:]
  private typealias Waiter = (channelID: Int64, continuation: CheckedContinuation<Void, Never>)
  private var waiters: [UInt64: Waiter] = [:]
  private var cancelled: Set<UInt64> = []
  private var nextToken: UInt64 = 0

  public init() {}

  /// Where `channelID` stands now. Read it before draining, then pass it to
  /// ``wait(for:after:)``, so a hint that lands mid-drain is not missed.
  public func revision(of channelID: Int64) -> UInt64 { revisions[channelID] ?? 0 }

  /// Takes a pushed `Updates` container. `updatesTooLong` says the server will
  /// not enumerate what changed, so every channel is hinted.
  public func deliver(_ updates: TL.UpdatesType) {
    switch updates {
    case .updates(let value): deliver(value.updates)
    case .updatesCombined(let value): deliver(value.updates)
    case .updateShort(let value): deliver([value.update])
    case .updatesTooLong: hintAll()
    // The short forms carry a private message, which names no channel.
    case .updateShortMessage, .updateShortChatMessage, .updateShortSentMessage: break
    }
  }

  /// Hints every channel named by an update — a new, edited or deleted channel
  /// message, or an `updateChannelTooLong`.
  public func deliver(_ updates: [TL.UpdateType]) {
    for channelID in Set(updates.compactMap(ChannelUpdateFilter.hintedChannelID(of:))) {
      hint(channelID)
    }
  }

  public func hint(_ channelID: Int64) {
    revisions[channelID] = revision(of: channelID) + 1
    for (token, waiter) in waiters where waiter.channelID == channelID {
      waiters.removeValue(forKey: token)
      waiter.continuation.resume()
    }
  }

  public func hintAll() {
    for channelID in Set(revisions.keys).union(waiters.values.map(\.channelID)) {
      hint(channelID)
    }
  }

  /// Suspends until `channelID` is hinted past `revision`. Returns at once if
  /// that already happened, and when the calling task is cancelled.
  public func wait(for channelID: Int64, after revision: UInt64) async {
    guard self.revision(of: channelID) <= revision else { return }
    let token = nextToken
    nextToken += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          cancelled.remove(token) == nil, !Task.isCancelled,
          self.revision(of: channelID) <= revision
        else {
          continuation.resume()
          return
        }
        waiters[token] = (channelID, continuation)
      }
    } onCancel: {
      Task { await self.stopWaiting(token) }
    }
  }

  /// Releases a cancelled waiter, remembering the token when cancellation beats
  /// the continuation into the actor.
  private func stopWaiting(_ token: UInt64) {
    if let waiter = waiters.removeValue(forKey: token) {
      waiter.continuation.resume()
    } else {
      cancelled.insert(token)
    }
  }
}
