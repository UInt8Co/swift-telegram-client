#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import MTProtoClientKit
import TelegramClient
import TelegramSchema
import Testing

@Suite struct UpdateIntakeTests {
  @Test func idleTicksRespectEachChannelDeadlineAndServerTimeout() {
    let now = ContinuousClock.now
    var schedule = RecoverySchedule(accountInterval: .seconds(60), safetySeconds: { 600 })
    let channels = (1...53).map(Int64.init)
    #expect(schedule.due(channels, now: now) == channels)
    for id in channels { schedule.recovered(id, timeout: nil, now: now, safetySeconds: 600) }
    for second in stride(from: 15, to: 600, by: 15) {
      #expect(schedule.due(channels, now: now.advanced(by: .seconds(second))).isEmpty)
    }
    schedule.recovered(7, timeout: 30, now: now)
    #expect(schedule.due(channels, now: now.advanced(by: .seconds(29))).isEmpty)
    #expect(schedule.due(channels, now: now.advanced(by: .seconds(30))) == [7])
    schedule.accountAdvanced(now: now)
    #expect(schedule.account == now.advanced(by: .seconds(60)))
  }

  @Test func simulatedIdleHourReducesPolls() {
    let now = ContinuousClock.now
    let channels = (1...53).map(Int64.init)
    var schedule = RecoverySchedule(accountInterval: .seconds(60), safetySeconds: { 600 })
    for id in channels { schedule.recovered(id, timeout: nil, now: now, safetySeconds: 600) }
    schedule.accountAdvanced(now: now)
    var channelCalls = 0
    var accountCalls = 0
    for second in 1...3600 {
      let tick = now.advanced(by: .seconds(second))
      for id in schedule.due(channels, now: tick) {
        channelCalls += 1
        schedule.recovered(id, timeout: nil, now: tick, safetySeconds: 600)
      }
      if schedule.account <= tick { accountCalls += 1; schedule.accountAdvanced(now: tick) }
    }
    #expect(channelCalls == 318 && accountCalls == 60)
    print("INTAKE_SCHEDULE simulated idle hour, 53 channels, 600s safety: channel RPCs 12720 -> \(channelCalls); account RPCs 240 -> \(accountCalls), excluding startup")
  }

  @Test func gapRecoversOnlyItsChannelBeforeDelivery() async throws {
    let state = IntakeState()
    for id in [Int64(1), 2, 3] {
      try await ChannelRecovery.push(id, position: 10,
        updates: [.channel(id, pts: id == 2 ? 13 : 11, count: 1)], recover: { position in
          #expect(position == 10)
          await state.record("recover:\(id)")
          return 12
        }, deliver: { await state.record("push:\(id)") }, commit: { next in
          await state.commit(id, next)
        })
    }
    #expect(await state.events == ["push:1", "recover:2", "push:2", "push:3"])
    #expect(await state.positions == [1: 11, 2: 13, 3: 11])
  }

  @Test func unknownPositionAndTooLongHintRecoverOnce() async throws {
    for initial: Int32? in [nil, 10] {
      let state = IntakeState()
      try await ChannelRecovery.push(1, position: initial, updates: [.channelTooLong(1)], recover: { start in
        #expect(start == initial ?? 1)
        await state.record("recover")
        return 50
      }, deliver: { await state.record("delivered") }, commit: { next in await state.commit(1, next) })
      #expect(await state.events == ["recover", "delivered"])
      #expect(await state.positions[1] == 50)
    }
  }

  @Test func newContiguousChannelPushDoesNotFetch() async throws {
    let state = IntakeState()
    try await ChannelRecovery.push(1, position: nil, updates: [.channel(1, pts: 42, count: 1)], recover: { _ in
      Issue.record("An in-order push must not fetch a difference")
      return nil
    }, deliver: { }, commit: { next in await state.commit(1, next) })
    #expect(await state.positions[1] == 42)
  }

  @Test func failedHandlingAndIncompleteRecoveryNeverAdvancePastWork() async throws {
    let state = IntakeState()
    await #expect(throws: IntakeTestError.failed) {
      try await ChannelRecovery.push(1, position: 10, updates: [.channel(1, pts: 11, count: 1)],
        recover: { _ in nil }, deliver: { throw IntakeTestError.failed }, commit: { next in await state.commit(1, next) })
    }
    await #expect(throws: ChannelRecovery.Failure.self) {
      try await ChannelRecovery.push(1, position: 10, updates: [.channel(1, pts: 15, count: 1)],
        recover: { _ in 12 }, deliver: { await state.record("incorrect delivery") }, commit: { next in await state.commit(1, next) })
    }
    #expect(await state.positions.isEmpty)
    #expect(await state.events.isEmpty)
  }

  @Test func aSnapshotBeyondThePushDoesNotDiscardItsKnownPayload() async throws {
    let state = IntakeState()
    try await ChannelRecovery.push(1, position: 10, updates: [.channel(1, pts: 15, count: 1)],
      recover: { _ in 20 }, deliver: { await state.record("queued payload") }, commit: { next in await state.commit(1, next) })
    #expect(await state.events == ["queued payload"])
    #expect(await state.positions[1] == 20)
  }

  @Test func inaccessibleChannelDoesNotRecreateItsCheckpoint() async throws {
    let state = IntakeState()
    try await ChannelRecovery.push(1, position: 10, updates: [.channelTooLong(1)],
      recover: { _ in nil }, deliver: { await state.record("handled remaining push") }, commit: { next in await state.commit(1, next) })
    #expect(await state.positions.isEmpty)
    #expect(await state.events.count == 1)
  }

  @Test func slowChannelDoesNotDelayAnotherChatAndKeepsItsOwnOrder() async throws {
    let queue = makeQueue()
    let started = IntakeGate()
    let release = IntakeGate()
    let state = IntakeState()
    let recovery = await queue.submit(1) {
      await state.record("recovery started")
      await started.open()
      await release.wait()
      await state.record("recovery handled")
    }
    try #require(await queue.metrics().depth == 1)
    await started.wait()
    let same = await queue.submit(1) { await state.record("same chat push") }
    let other = await queue.submit(2) { await state.record("other chat push") }
    try await other.wait()
    #expect(await state.events == ["recovery started", "other chat push"])
    await release.open()
    try await recovery.wait()
    try await same.wait()
    #expect(await state.events == ["recovery started", "other chat push", "recovery handled", "same chat push"])
    await queue.stop()
  }

  @Test func accountCommitWaitsForAllChatsWhileLaterPushesKeepMoving() async throws {
    let chats = makeQueue()
    let account = makeQueue()
    let release = IntakeGate()
    let state = IntakeState()
    let slow = await chats.submit(1) { await release.wait() }
    let fast = await chats.submit(2) { await state.record("first push") }
    let committed = await account.submit(0) {
      try await slow.wait()
      try await fast.wait()
      await state.record("account commit")
    }
    let later = await chats.submit(2) { await state.record("next push") }
    try await later.wait()
    #expect(await state.events == ["first push", "next push"])
    await release.open()
    try await committed.wait()
    #expect(await state.events.last == "account commit")
    await chats.stop()
    await account.stop()
  }

  @Test func shutdownCancelsActiveWorkAndDoesNotRunItsQueuedSuccessor() async throws {
    let queue = makeQueue()
    let started = IntakeGate()
    let state = IntakeState()
    let active = await queue.submit(1) {
      await started.open()
      try await Task.sleep(for: .seconds(30))
      await state.record("unhandled")
    }
    await started.wait()
    let pending = await queue.submit(1) { await state.record("queued") }
    await queue.stop()
    await #expect(throws: CancellationError.self) { try await active.wait() }
    await #expect(throws: CancellationError.self) { try await pending.wait() }
    #expect(await state.events.isEmpty)
  }

  @Test func oneFailingChannelRetriesWithoutReplayingSuccessfulChannels() async throws {
    let state = IntakeState()
    let queue = OrderedWorkQueue<Int>(retry: { error, _ in
      ServerTransientFailure.describes(error) ? .milliseconds(20) : nil
    }, failed: { error in Issue.record("Unexpected fatal error: \(error)") })
    let failedOnce = await queue.submit(1) {
      let attempt = await state.attempt(1)
      if attempt == 1 { throw MTProtoRPCError(code: 500, message: "INTERNAL") }
    }
    let healthy = await queue.submit(2) { _ = await state.attempt(2) }
    try await healthy.wait()
    try await failedOnce.wait()
    #expect(await state.attempts == [1: 2, 2: 1])
    await queue.stop()
  }

  @Test func recoveryConcurrencyBudgetLeavesPushesIndependent() async throws {
    let queue = makeQueue()
    let limit = ConcurrencyPermitPool(10)
    let allStarted = IntakeGate()
    let release = IntakeGate()
    let state = IntakeState()
    var receipts: [WorkReceipt] = []
    for id in 1...11 {
      receipts.append(await queue.submit(id) {
        try await limit.run {
          let count = await state.attempt(0)
          if count == 10 { await allStarted.open() }
          await release.wait()
        }
      })
    }
    await allStarted.wait()
    let pushed = await queue.submit(12) { await state.record("pushed") }
    try await pushed.wait()
    #expect(await state.attempts[0] == 10)
    #expect(await state.events == ["pushed"])
    await release.open()
    for receipt in receipts { try await receipt.wait() }
    #expect(await state.attempts[0] == 11)
    await queue.stop()
  }

  @Test func chatlessBarrierWaitsForEarlierChatsAndHoldsLaterChats() async throws {
    let queue = makeQueue()
    let release = IntakeGate()
    let state = IntakeState()
    let first = await queue.submit(1) { await release.wait(); await state.record("before") }
    let barrier = await queue.submit(0, barrier: true) { await state.record("delete") }
    let after = await queue.submit(2) { await state.record("after") }
    #expect(await queue.metrics().depth == 3)
    await release.open()
    try await first.wait()
    try await barrier.wait()
    try await after.wait()
    #expect(await state.events == ["before", "delete", "after"])
    await queue.stop()
  }

  @Test func tooLongBackfillFinishesBeforeCheckpointAndTimeoutIsReturned() async throws {
    let state = IntakeState()
    let timeout = try await ChannelRecovery.read(from: 10, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { pts in
      #expect(pts == 10)
      return .init(updates: [], users: [], chats: [], pts: 90, isFinal: true, timeout: 123,
            skippedGap: true, topMessageID: 80)
    }, handle: { _ in await state.record("snapshot") }, backfill: { top in
      #expect(top == 80)
      await state.record("backfill")
      return .init(messages: 7, pages: 2, reachedCutoff: true)
    }, commit: { pts in await state.record("commit:\(pts)") }, reportGap: { gap in
      #expect(!gap.initialSnapshot && gap.error == nil)
      #expect(String(gap.fromPTS) == "10")
      #expect(gap.nextPTS.map(String.init) == "90")
      #expect(String(gap.fromPTS == 1) == "false")
      #expect(gap.coverage.map { String($0.messages) } == "7")
      #expect(String(gap.coverage?.reachedCutoff ?? false) == "true")
      await state.record("gap reported")
    })
    #expect(timeout == 123)
    #expect(await state.events == ["snapshot", "backfill", "commit:90", "gap reported"])
  }

  @Test func failedBackfillDoesNotCommitSnapshot() async throws {
    let state = IntakeState()
    await #expect(throws: IntakeTestError.failed) {
      _ = try await ChannelRecovery.read(from: 10, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { _ in
        .init(updates: [], users: [], chats: [], pts: 90, isFinal: true, skippedGap: true, topMessageID: 80)
      }, handle: { _ in }, backfill: { _ in throw IntakeTestError.failed }, commit: { pts in await state.commit(1, pts) })
    }
    #expect(await state.positions.isEmpty)
  }

  @Test func transientReadFailsFastAndKeepsLastHandledPage() async throws {
    let state = IntakeState()
    await #expect(throws: MTProtoRPCError(code: 500, message: "INTERNAL")) {
      _ = try await ChannelRecovery.read(from: 10, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { pts in
        _ = await state.attempt(1)
        if pts == 11 { throw MTProtoRPCError(code: 500, message: "INTERNAL") }
        return .init(updates: [], users: [], chats: [], pts: 11, isFinal: false)
      }, handle: { _ in }, backfill: { _ in .init(reachedStart: true) }, commit: { pts in await state.commit(1, pts) })
    }
    #expect(await state.attempts[1] == 2)
    #expect(await state.positions[1] == 11)
  }

  @Test func rejectedStoredPTSRestartsAtOneOnlyOnce() async throws {
    let state = IntakeState()
    await #expect(throws: MTProtoRPCError.self) {
      _ = try await ChannelRecovery.read(from: 10, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { pts in
        await state.record("fetch:\(pts)")
        throw MTProtoRPCError(code: 400, message: "PERSISTENT_TIMESTAMP_INVALID")
      }, handle: { _ in }, backfill: { _ in .init(reachedStart: true) }, commit: { _ in })
    }
    #expect(await state.events == ["fetch:10", "fetch:1"])
  }

  @Test func serverReplicationFailureRetriesOriginalPTSWithoutReset() async throws {
    let state = IntakeState()
    let error = MTProtoRPCError(code: 500, message: "PERSISTENT_TIMESTAMP_OUTDATED")
    #expect(ServerTransientFailure.describes(error))
    for attempt in 1...2 {
      do {
        _ = try await ChannelRecovery.read(from: 42, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { pts in
          await state.record("fetch:\(pts)")
          if await state.attempt(1) == 1 { throw error }
          return .init(updates: [], users: [], chats: [], pts: 45, isFinal: true)
        }, handle: { _ in }, backfill: { _ in
          Issue.record("A replication error must not force a snapshot")
          return .init(reachedStart: true)
        }, commit: { pts in await state.commit(1, pts) }, rejected: { _ in
          Issue.record("A replication error does not reject the checkpoint")
        }, reportGap: { _ in Issue.record("No history was skipped") })
        #expect(attempt == 2)
      } catch {
        #expect(attempt == 1)
        #expect(await state.positions.isEmpty)
      }
    }
    #expect(await state.events == ["fetch:42", "fetch:42"])
    #expect(await state.positions[1] == 45)
  }

  @Test(arguments: ["PERSISTENT_TIMESTAMP_INVALID", "PERSISTENT_TIMESTAMP_EMPTY"])
  func rejectedPTSReportsResetAndCoverageAfterCommit(_ message: String) async throws {
    let state = IntakeState()
    _ = try await ChannelRecovery.read(from: 42, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { pts in
      if pts == 42 { throw MTProtoRPCError(code: 400, message: message) }
      #expect(pts == 1)
      return .init(updates: [], users: [], chats: [], pts: 90, isFinal: true,
            skippedGap: true, topMessageID: 0)
    }, handle: { _ in }, backfill: { top in
      #expect(top == 0)
      return .init(reachedStart: true)
    }, commit: { pts in await state.commit(1, pts) }, reportGap: { gap in
      #expect(await state.positions[1] == 90)
      #expect(gap.initialPTS == 42 && gap.fromPTS == 1 && gap.resetAfterRejection)
      #expect(String(gap.fromPTS == 1) == "true")
      #expect(!gap.initialSnapshot && gap.error == nil)
      await state.record("gap")
    })
    #expect(await state.events == ["gap"])
  }

  @Test func temporaryBackfillFailureReportsGapOnlyAfterSuccessfulRetry() async throws {
    let state = IntakeState()
    for attempt in 1...2 {
      do {
        _ = try await ChannelRecovery.read(from: 1, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { _ in
          .init(updates: [], users: [], chats: [], pts: 90, isFinal: true,
             skippedGap: true, topMessageID: 80)
        }, handle: { _ in }, backfill: { _ in
          if await state.attempt(1) == 1 { throw MTProtoRPCError(code: 500, message: "INTERNAL") }
          return .init(messages: 2, pages: 1, reachedStart: true)
        }, commit: { pts in await state.commit(1, pts) }, reportGap: { gap in
          #expect(gap.initialSnapshot && !gap.resetAfterRejection)
          await state.record("gap")
        })
      } catch {
        #expect(attempt == 1)
        #expect(await state.positions.isEmpty)
        #expect(await state.events.isEmpty)
      }
    }
    #expect(await state.events == ["gap"])
  }

  @Test(arguments: [0, 1, 2, 3])
  func uncoveredGapIsAnErrorAndNeverCommits(_ failure: Int) async throws {
    let state = IntakeState()
    await #expect(throws: (any Error).self) {
      _ = try await ChannelRecovery.read(from: 10, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { _ in
        .init(updates: [], users: [], chats: [], pts: failure == 0 ? nil : 90, isFinal: true,
           skippedGap: true, topMessageID: failure == 1 ? nil : 80)
      }, handle: { _ in }, backfill: { _ in
        if failure == 2 { throw IntakeTestError.failed }
        return .init(messages: 3, pages: 1) // No verified stopping boundary.
      }, commit: { pts in await state.commit(1, pts) }, reportGap: { gap in
        #expect(gap.error != nil)
        await state.record("gap")
      })
    }
    #expect(await state.positions.isEmpty)
    #expect(await state.events == ["gap"])
  }

  @Test func cancelledBackfillDoesNotReportCompletedOrUnrecoverableGap() async throws {
    let state = IntakeState()
    await #expect(throws: CancellationError.self) {
      _ = try await ChannelRecovery.read(from: 10, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { _ in
        .init(updates: [], users: [], chats: [], pts: 90, isFinal: true, skippedGap: true, topMessageID: 80)
      }, handle: { _ in }, backfill: { _ in throw CancellationError() },
      commit: { pts in await state.commit(1, pts) }, reportGap: { _ in Issue.record("Cancelled attempt") })
    }
    #expect(await state.positions.isEmpty)
  }

  @Test func backfillCrossesEmptyPagesAndIncludesRecentEditsAtCreationCutoff() async throws {
    let state = IntakeState()
    let coverage = try await ChannelBackfill.read(topID: 300, cutoff: 1000, fetch: { ids in
      await state.record("fetch:\(ids.lowerBound)-\(ids.upperBound)")
      if ids.lowerBound == 201 { return .init(updates: [], users: [], chats: []) }
      let messages: [TL.MessageType] = [
        .message(.init(id: 199, peerId: .peerChannel(.init(channelId: 1)), date: 1000, message: "new")),
        .message(.init(id: 198, peerId: .peerChannel(.init(channelId: 1)), date: 999, message: "edited", editDate: 1001)),
        .messageService(.init(id: 197, peerId: .peerChannel(.init(channelId: 1)), date: 999, action: .messageActionEmpty(.init()))),
        .message(.init(id: 196, peerId: .peerChannel(.init(channelId: 1)), date: 998, message: "old")),
        .messageEmpty(.init(id: 195))
      ]
      return ChannelHistoryDecoder.decode(.messages(.init(messages: messages, topics: [], chats: [], users: [])), forChannelID: 1)
    }, handle: { page in
      for update in page.updates {
        if case .updateNewChannelMessage(let value) = update, case .message(let m) = value.message {
          await state.record("message:\(m.id)")
        }
      }
    })
    #expect(coverage == .init(messages: 2, pages: 2, reachedCutoff: true))
    #expect(await state.events == ["fetch:201-300", "fetch:101-200", "message:198", "message:199"])
  }

  @Test func backfillWaitsOutFloodAtTheCurrentPageWithoutRereadingHandledPages() async throws {
    let state = IntakeState()
    let floods = IntakeState()
    let coverage = try await ChannelBackfill.read(topID: 250, cutoff: 1000, fetch: { ids in
      await state.record("fetch:\(ids.lowerBound)-\(ids.upperBound)")
      if ids.lowerBound == 1, await floods.events.count < 2 {
        await floods.record("flood")
        throw MTProtoRPCError(code: 420, message: "FLOOD_WAIT_30")
      }
      return .init(updates: [], users: [], chats: [])
    }, handle: { page in
      await state.record("handle")
    }, sleep: { wait in
      await state.record("sleep:\(wait.components.seconds)")
    }, jitter: { $0 + .seconds(2) }) // The directive already adds one second of margin.
    #expect(coverage == .init(messages: 0, pages: 3, reachedStart: true))
    let events = await state.events
    #expect(events == [
      "fetch:151-250", "handle", "fetch:51-150", "handle",
      "fetch:1-50", "sleep:33", "fetch:1-50", "sleep:33", "fetch:1-50", "handle"
    ])
  }

  @Test func flooredBackfillReadsOldestFirstUpToTheTopAndFiltersByCutoff() async throws {
    let state = IntakeState()
    let coverage = try await ChannelBackfill.read(topID: 350, cutoff: 1000, floorID: 140, fetch: { ids in
      await state.record("fetch:\(ids.lowerBound)-\(ids.upperBound)")
      guard ids.lowerBound == 141 else { return .init(updates: [], users: [], chats: []) }
      let messages: [TL.MessageType] = [
        .message(.init(id: 142, peerId: .peerChannel(.init(channelId: 1)), date: 1001, message: "new")),
        .message(.init(id: 141, peerId: .peerChannel(.init(channelId: 1)), date: 999, message: "old"))
      ]
      return ChannelHistoryDecoder.decode(.messages(.init(messages: messages, topics: [], chats: [], users: [])), forChannelID: 1)
    }, handle: { _ in await state.record("handle") })
    #expect(coverage == .init(messages: 1, pages: 3, reachedCutoff: true, reachedFloor: true))
    let events = await state.events
    #expect(events == ["fetch:141-240", "handle", "fetch:241-340", "handle", "fetch:341-350", "handle"])
  }

  @Test(arguments: [Int32(350), 400])
  func floorAtOrAboveTheTopReadsNothing(_ floor: Int32) async throws {
    let coverage = try await ChannelBackfill.read(topID: 350, cutoff: 1000, floorID: floor, fetch: { _ in
      Issue.record("no page should be read"); return .init(updates: [], users: [], chats: [])
    }, handle: { _ in })
    #expect(coverage == .init(reachedFloor: true))
  }

  @Test func flooredBackfillCompletesTheGap() async throws {
    let state = IntakeState()
    _ = try await ChannelRecovery.read(from: 9, channelID: 1, isTransient: ServerTransientFailure.describes, fetch: { _ in
      .init(updates: [], users: [], chats: [], pts: 20, isFinal: true, skippedGap: true, topMessageID: 50)
    }, handle: { _ in }, backfill: { _ in .init(pages: 1, reachedFloor: true) },
     commit: { pts in await state.commit(1, pts) })
    #expect(await state.positions[1] == 20)
  }

  @Test func recheckReadsAtMost500RetainedIDsInBatchesAndWaitsOutFloods() async throws {
    let state = IntakeState()
    let floods = IntakeState()
    let ids = (1...620).reversed().map { Int32($0) * 2 }
    let count = try await ChannelBackfill.recheck(ids: ids, cutoff: 1000, limit: 500, fetch: { batch in
      await state.record("fetch:\(batch.count):\(batch.first!)-\(batch.last!)")
      if batch.first == 1040, await floods.events.isEmpty {
        await floods.record("flood")
        throw MTProtoRPCError(code: 420, message: "FLOOD_WAIT_5")
      }
      guard batch.first == 1240 else { return .init(updates: [], users: [], chats: []) }
      let messages: [TL.MessageType] = [
        .message(.init(id: 1240, peerId: .peerChannel(.init(channelId: 1)), date: 1001, message: "edited", editDate: 2000)),
        .messageEmpty(.init(id: 1238))
      ]
      return ChannelHistoryDecoder.decode(.messages(.init(messages: messages, topics: [], chats: [], users: [])), forChannelID: 1)
    }, handle: { _ in await state.record("handle") }, sleep: { _ in await state.record("sleep") })
    #expect(count == 1)
    let events = await state.events
    #expect(events == [
      "fetch:100:1240-1042", "handle", "fetch:100:1040-842", "sleep", "fetch:100:1040-842", "handle",
      "fetch:100:840-642", "handle", "fetch:100:640-442", "handle", "fetch:100:440-242", "handle"
    ])
  }

  @Test func recheckWithNothingRetainedReadsNothing() async throws {
    let count = try await ChannelBackfill.recheck(ids: [], cutoff: 1000, limit: 500, fetch: { _ in
      Issue.record("no page should be read"); return .init(updates: [], users: [], chats: [])
    }, handle: { _ in })
    #expect(count == 0)
  }

  @Test func backfillStillThrowsNonFloodFailures() async throws {
    let sleeps = IntakeState()
    await #expect(throws: MTProtoRPCError.self) {
      _ = try await ChannelBackfill.read(topID: 100, cutoff: 1000, fetch: { _ in
        throw MTProtoRPCError(code: 400, message: "CHANNEL_PRIVATE")
      }, handle: { _ in }, sleep: { _ in await sleeps.record("sleep") })
    }
    #expect(await sleeps.events.isEmpty)
  }

  @Test(arguments: [Int32(0), 1, 101])
  func emptyHistoryReachesStartWithoutInventingDeletions(_ top: Int32) async throws {
    let coverage = try await ChannelBackfill.read(topID: top, cutoff: 1000, fetch: { _ in
      .init(updates: [], users: [], chats: [])
    }, handle: { page in #expect(page.updates.isEmpty) })
    #expect(coverage.reachedStart && !coverage.reachedCutoff && coverage.messages == 0)
    #expect(coverage.pages == (top == 0 ? 0 : top == 1 ? 1 : 2))
  }

  @Test func mailboxDrainsBoundedSlicesInArrivalOrderAndReportsAge() {
    let mailbox = PushMailbox()
    let now = ContinuousClock.now
    for id in (1...100).map(Int32.init) {
      mailbox.push(.updateShortSentMessage(.init(id: id, pts: id, ptsCount: 1, date: 1)), now: now)
    }
    #expect(mailbox.metrics(now: now.advanced(by: .seconds(8))).depth == 100)
    #expect(mailbox.metrics(now: now.advanced(by: .seconds(8))).oldest == .seconds(8))
    var ids: [Int32] = []
    while mailbox.metrics().depth > 0 {
      let entries = mailbox.drain().entries
      #expect(entries.count <= 32)
      ids += entries.compactMap { if case .updateShortSentMessage(let value) = $0.updates { value.id } else { nil } }
    }
    #expect(ids == Array(1...100))
    #expect(mailbox.metrics().oldest == .zero)
    mailbox.finish()
  }

  @Test func stalledLaneMetricsIncludeRunningHeadAndSeparateLaneMaxima() async throws {
    let queue = makeQueue()
    let release = IntakeGate(), started = IntakeGate()
    let now = ContinuousClock.now
    let first = await queue.submit(1, received: now.advanced(by: .seconds(2)), estimatedBytes: 1000) {
      await started.open(); await release.wait()
    }
    await started.wait()
    let one = await queue.metrics(now: now.advanced(by: .seconds(10)))
    let overhead = one.estimatedBytes - 1000
    #expect(overhead > 0)
    // A recovery head can precede a push whose receipt timestamp is older.
    let second = await queue.submit(1, received: now, estimatedBytes: 2000) { }
    let other = await queue.submit(2, received: now.advanced(by: .seconds(4)), estimatedBytes: 4000) {
      await release.wait()
    }
    let metrics = await queue.metrics(now: now.advanced(by: .seconds(10)))
    #expect(metrics.depth == 3 && metrics.maxDepth == 2 && metrics.laneCount == 2)
    #expect(metrics.oldest == .seconds(10))
    #expect(metrics.estimatedBytes == 7000 + 3 * overhead)
    #expect(metrics.maxEstimatedBytes == max(3000 + 2 * overhead, 4000 + overhead))
    await release.open()
    try await first.wait(); try await second.wait(); try await other.wait()
    // Receipt completion precedes removal of the head; stop waits for the workers.
    await queue.stop()
    #expect(await queue.metrics() == WorkMetrics())
    print("INTAKE_GAUGES stalled lanes: sum depth 3, max depth 2, oldest 10s; estimated bytes sum \(metrics.estimatedBytes), max \(metrics.maxEstimatedBytes); drained depth/bytes 0")
  }

  @Test func failedLaneDiscardsItsByteCountersAndPendingHeads() async throws {
    let queue = OrderedWorkQueue<Int>(retry: { _, _ in nil }, failed: { _ in })
    let started = IntakeGate(), release = IntakeGate()
    let first = await queue.submit(1, estimatedBytes: 500) {
      await started.open(); await release.wait(); throw IntakeTestError.failed
    }
    await started.wait()
    let pending = await queue.submit(1, estimatedBytes: 1000) { }
    #expect(await queue.metrics().depth == 2)
    await release.open()
    await #expect(throws: IntakeTestError.failed) { try await first.wait() }
    await #expect(throws: IntakeTestError.failed) { try await pending.wait() }
    await queue.stop()
    #expect(await queue.metrics() == WorkMetrics())
  }

  @Test func mailboxBytesFollowRetainedDecodedValuesWithoutEncoding() {
    let mailbox = PushMailbox()
    let now = ContinuousClock.now
    let small = TL.UpdatesType.updateShortMessage(.init(id: 1, userId: 1, message: "a", pts: 1, ptsCount: 1, date: 1))
    let large = TL.UpdatesType.updateShortMessage(.init(id: 2, userId: 1, message: String(repeating: "a", count: 1001), pts: 2, ptsCount: 1, date: 1))
    mailbox.push(small, now: now)
    let first = mailbox.metrics(now: now)
    mailbox.push(large, now: now.advanced(by: .seconds(2)))
    let both = mailbox.metrics(now: now.advanced(by: .seconds(10)))
    #expect(both.depth == 2 && both.oldest == .seconds(10))
    #expect(both.estimatedBytes == 2 * first.estimatedBytes + 1000)
    _ = mailbox.drain(limit: 1).entries
    let remaining = mailbox.metrics(now: now.advanced(by: .seconds(10)))
    #expect(remaining.depth == 1 && remaining.oldest == .seconds(8))
    #expect(remaining.estimatedBytes == first.estimatedBytes + 1000)
    _ = mailbox.drain().entries
    #expect(mailbox.metrics() == WorkMetrics())
    mailbox.finish()
  }

  @Test func flushWaitsForInFlightWriteAndPersistsNewestHandledSnapshot() async throws {
    let started = IntakeGate()
    let release = IntakeGate()
    let state = IntakeState()
    let writer = CheckpointWriter(saved: 0) { value in
      if value == 1 { await started.open(); await release.wait() }
      await state.record("saved:\(value)")
    }
    await writer.update(1, revision: 1)
    let first = Task { try await writer.flush() }
    await started.wait()
    await writer.update(2, revision: 2)
    let shutdown = Task { try await writer.flush() }
    await release.open()
    try await first.value
    try await shutdown.value
    #expect(await state.events == ["saved:1", "saved:2"])
    #expect(await writer.writes == 2)
  }

  @Test func unchangedFileWriteKeepsTheExistingFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileKeyValueStore(directory: directory)
    try await store.write(Data([1, 2]), key: "test")
    let file = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path).first.map { directory.appendingPathComponent($0) })
    let before = try FileManager.default.attributesOfItem(atPath: file.path)
    try await store.write(Data([1, 2]), key: "test")
    let after = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(before[.systemFileNumber] as? UInt64 == after[.systemFileNumber] as? UInt64)
    #expect(after[.posixPermissions] as? Int == 0o600)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["TELEGRAM_INTAKE_BENCHMARK"] == "1"))
  func controlledSlowRecoveryLatency() async throws {
    let started = IntakeGate()
    let release = IntakeGate()
    let queue = makeQueue()
    let state = IntakeState()
    let oldStart = ContinuousClock.now
    try await Task.sleep(for: .milliseconds(200))
    let oldDelay = oldStart.duration(to: .now)
    let slow = await queue.submit(1) {
      await started.open()
      try await Task.sleep(for: .milliseconds(200))
      await release.wait()
      await state.record("slow done")
    }
    await started.wait()
    let newStart = ContinuousClock.now
    let push = await queue.submit(2) { await state.record("push handled") }
    try await push.wait()
    let newDelay = newStart.duration(to: .now)
    #expect(await state.events.first == "push handled")
    await release.open()
    try await slow.wait()
    print("INTAKE_LATENCY controlled 200ms recovery: serial barrier \(oldDelay); independent chat push \(newDelay)")
    await queue.stop()
  }

  private func makeQueue() -> OrderedWorkQueue<Int> {
    OrderedWorkQueue(retry: { _, _ in nil }, failed: { error in Issue.record("Unexpected intake failure: \(error)") })
  }
}

private enum IntakeTestError: Error, Equatable { case failed }

private actor IntakeGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if !opened { await withCheckedContinuation { waiters.append($0) } }
  }
  func open() {
    opened = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

private actor IntakeState {
  private(set) var events: [String] = []
  private(set) var positions: [Int64: Int32] = [:]
  private(set) var attempts: [Int: Int] = [:]
  func record(_ event: String) { events.append(event) }
  func commit(_ id: Int64, _ pts: Int32) { positions[id] = pts }
  func attempt(_ id: Int) -> Int { attempts[id, default: 0] += 1; return attempts[id, default: 0] }
}

private struct IntakeFloodTransport: TLClientTransport {
  func send(_ requestBody: Data) async throws -> Data {
    throw MTProtoRPCError(code: 420, message: "FLOOD_WAIT_30")
  }
}
