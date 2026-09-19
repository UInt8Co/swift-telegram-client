import TelegramSchema
import Synchronization
import Testing

@testable import TelegramClient

@Suite struct UpdateHubTests {
  /// `Mutex` is non-copyable, so a task closure reaches it through a box.
  private final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func add(_ amount: Int) { value.withLock { $0 += amount } }
  }

  private static let channelID: Int64 = 500
  private static let otherID: Int64 = 501

  private static func post(in channelID: Int64) -> TL.UpdateType {
    .updateNewChannelMessage(
      TL.UpdateNewChannelMessage(
        message: .message(
          TL.Message(
            post: true, id: 1, peerId: .peerChannel(TL.PeerChannel(channelId: channelID)),
            date: 1, message: "hi")),
        pts: 2, ptsCount: 1))
  }

  private static func tooLong(_ channelID: Int64, pts: Int32? = nil) -> TL.UpdateType {
    .updateChannelTooLong(TL.UpdateChannelTooLong(channelId: channelID, pts: pts))
  }

  @Test("a hint that lands before the wait returns it at once")
  func aHintBeforeTheWaitDoesNotBlock() async {
    let hub = UpdateHub()
    let revision = await hub.revision(of: Self.channelID)
    await hub.deliver([Self.post(in: Self.channelID)])
    await hub.wait(for: Self.channelID, after: revision)
    #expect(await hub.revision(of: Self.channelID) == revision + 1)
  }

  @Test("a hint that lands during the wait wakes it", .timeLimit(.minutes(1)))
  func aHintDuringTheWaitWakesIt() async throws {
    let hub = UpdateHub()
    let revision = await hub.revision(of: Self.channelID)
    let waiting = Task { await hub.wait(for: Self.channelID, after: revision) }
    try await Task.sleep(for: .milliseconds(50))
    await hub.deliver([Self.tooLong(Self.channelID, pts: 40)])
    await waiting.value
    #expect(await hub.revision(of: Self.channelID) == revision + 1)
  }

  @Test("every waiter on a channel wakes, and no one else does", .timeLimit(.minutes(1)))
  func wakesEveryWaiterOnThatChannelOnly() async throws {
    let hub = UpdateHub()
    let woken = Counter()
    var ours: [Task<Void, Never>] = []
    for _ in 0..<3 {
      ours.append(
        Task {
          await hub.wait(for: Self.channelID, after: 0)
          woken.add(1)
        })
    }
    let other = Task {
      await hub.wait(for: Self.otherID, after: 0)
      woken.add(100)
    }
    // One hint is enough however the tasks are scheduled: a waiter that has not
    // parked yet sees the raised revision and returns without parking.
    try await Task.sleep(for: .milliseconds(50))
    await hub.deliver([Self.post(in: Self.channelID)])
    for task in ours { await task.value }
    #expect(woken.count == 3)
    #expect(await hub.revision(of: Self.otherID) == 0)
    other.cancel()
    await other.value
  }

  @Test("updatesTooLong hints every channel anyone is watching")
  func updatesTooLongHintsEveryChannel() async {
    let hub = UpdateHub()
    await hub.deliver([Self.post(in: Self.channelID)])
    await hub.deliver([Self.post(in: Self.otherID)])
    let before = (
      await hub.revision(of: Self.channelID), await hub.revision(of: Self.otherID)
    )
    await hub.deliver(.updatesTooLong(TL.UpdatesTooLong()))
    #expect(await hub.revision(of: Self.channelID) == before.0 + 1)
    #expect(await hub.revision(of: Self.otherID) == before.1 + 1)
  }

  @Test("a pushed Updates container is unwrapped, a private message is not a hint")
  func unwrapsPushedContainers() async {
    let hub = UpdateHub()
    await hub.deliver(
      .updateShort(
        TL.UpdateShort(update: Self.tooLong(Self.channelID, pts: 7), date: 1)))
    #expect(await hub.revision(of: Self.channelID) == 1)

    await hub.deliver(
      .updates(
        TL.Updates_(
          updates: [Self.post(in: Self.channelID), Self.post(in: Self.otherID)],
          users: [], chats: [], date: 1, seq: 0)))
    #expect(await hub.revision(of: Self.channelID) == 2)
    #expect(await hub.revision(of: Self.otherID) == 1)

    // A private message names no channel, so it hints nothing.
    await hub.deliver(
      .updateShortMessage(
        TL.UpdateShortMessage(id: 1, userId: 2, message: "hello", pts: 3, ptsCount: 1, date: 1)))
    await hub.deliver([
      .updateUserTyping(TL.UpdateUserTyping(userId: 2, action: .sendMessageTypingAction(
        TL.SendMessageTypingAction())))
    ])
    #expect(await hub.revision(of: Self.channelID) == 2)
  }

  @Test("cancelling a waiting task releases it", .timeLimit(.minutes(1)))
  func cancellationReleasesAWaiter() async throws {
    let hub = UpdateHub()
    let waiting = Task { await hub.wait(for: Self.channelID, after: 0) }
    try await Task.sleep(for: .milliseconds(50))
    waiting.cancel()
    // Would hang here if cancellation left the continuation parked.
    await waiting.value
    #expect(await hub.revision(of: Self.channelID) == 0)
  }

  @Test("a wait started by an already-cancelled task returns", .timeLimit(.minutes(1)))
  func anAlreadyCancelledTaskDoesNotPark() async {
    let hub = UpdateHub()
    let waiting = Task {
      // Cancelled before the actor is ever entered.
      while !Task.isCancelled { await Task.yield() }
      await hub.wait(for: Self.channelID, after: 0)
    }
    waiting.cancel()
    await waiting.value
  }

  @Test("already-cancelled waits do not retain late cancellation markers", .timeLimit(.minutes(1)))
  func alreadyCancelledWaitsDoNotLeakTokens() async throws {
    let hub = UpdateHub()
    for _ in 0..<100 {
      let waiting = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await hub.wait(for: Self.channelID, after: 0)
      }
      await waiting.value
    }
    // The cancellation handler forwards into the actor in its own Task, which
    // can arrive after wait() has already returned for a cancelled caller.
    try await Task.sleep(for: .milliseconds(50))
    #expect(await hub.retainedWaitTokenCount == 0)
  }

  @Test("cancellation racing a hint releases all waiter state", .timeLimit(.minutes(1)))
  func hintAndCancellationDoNotRetainTokens() async throws {
    let hub = UpdateHub()
    for _ in 0..<100 {
      let revision = await hub.revision(of: Self.channelID)
      let waiting = Task { await hub.wait(for: Self.channelID, after: revision) }
      await hub.hint(Self.channelID)
      waiting.cancel()
      await waiting.value
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await hub.retainedWaitTokenCount == 0)
  }
}
