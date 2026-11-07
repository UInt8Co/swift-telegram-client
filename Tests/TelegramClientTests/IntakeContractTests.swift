#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import MTProtoClientKit
import TelegramClient
import TelegramSchema
import Testing

@Suite(.timeLimit(.minutes(1))) struct IntakeContractTests {
  @Test func cancellingReceiptWaiterDoesNotFinishSharedWork() async throws {
    let receipt = WorkReceipt()
    let started = WorkReceipt()
    let cancelled = Task {
      await started.finish(.success(()))
      try await receipt.wait()
    }
    try await started.wait()
    cancelled.cancel()
    // Must finish while the shared receipt is still unresolved.
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let other = Task { try await receipt.wait() }
    await receipt.finish(.success(()))
    try await other.value
    await receipt.finish(.failure(CancellationError()))
    try await receipt.wait()
  }

  @Test func cancelledPermitWaiterDoesNotNeedTheHolderToRelease() async throws {
    let pool = ConcurrencyPermitPool(1)
    let started = WorkReceipt(), release = WorkReceipt(), queued = WorkReceipt()
    let holder = Task {
      try await pool.run {
        await started.finish(.success(()))
        try await release.wait()
      }
    }
    try await started.wait()
    let waiter = Task {
      await queued.finish(.success(()))
      try await pool.run { Issue.record("Cancelled operation ran"); return () }
    }
    try await queued.wait()
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    await release.finish(.success(()))
    try await holder.value
    #expect(try await pool.run { 7 } == 7)
  }

  @Test(arguments: [0, -1, Int.min]) func nonpositivePermitCapacityIsOne(_ capacity: Int) async throws {
    let pool = ConcurrencyPermitPool(capacity)
    #expect(try await pool.run { 3 } == 3)
  }

  @Test func shutdownCancelsAWorkerWaitingForExternalReceipt() async throws {
    let queue = OrderedWorkQueue<Int>(retry: { _, _ in nil }, failed: { _ in })
    let external = WorkReceipt(), started = WorkReceipt()
    let job = await queue.submit(1) {
      await started.finish(.success(()))
      try await external.wait()
    }
    try await started.wait()
    await queue.stop()
    await #expect(throws: CancellationError.self) { try await job.wait() }
    let afterStop = await queue.submit(1) { Issue.record("Stopped work ran") }
    await #expect(throws: CancellationError.self) { try await afterStop.wait() }
    #expect(await queue.metrics().depth == 0)
  }

  @Test func selectiveBarrierLeavesUnselectedKeysIndependent() async throws {
    let queue = OrderedWorkQueue<Int>(barrierIncludes: { $0 < 10 }, retry: { _, _ in nil }, failed: { _ in })
    let release = WorkReceipt()
    let first = await queue.submit(1) { try await release.wait() }
    let barrier = await queue.submit(0, barrier: true) {}
    let after = await queue.submit(2) {}
    let independent = await queue.submit(10) {}
    try await independent.wait()
    #expect(await queue.metrics().depth >= 3)
    await release.finish(.success(()))
    try await first.wait(); try await barrier.wait(); try await after.wait()
    await queue.stop()
  }

  @Test func boundedDrainPreservesPollAndSignalsRemainingWork() async throws {
    let mailbox = PushMailbox()
    var wakes = mailbox.wakes.makeAsyncIterator()
    for id: Int32 in [1, 2, 3] {
      mailbox.push(.updateShortSentMessage(.init(id: id, pts: id, ptsCount: 1, date: 1)))
    }
    mailbox.poll()
    _ = await wakes.next()
    let first = mailbox.drain(limit: 0)
    #expect(first.entries.count == 1 && first.poll)
    _ = await wakes.next() // Partial drain must have re-signalled.
    let rest = mailbox.take()
    #expect(rest.pushes.count == 2 && !rest.poll)
    mailbox.poll()
    #expect(mailbox.take().poll)
    #expect(!mailbox.take().poll)
    mailbox.finish()
  }

  @Test func mailboxCompactionKeepsArrivalOrder() {
    let mailbox = PushMailbox()
    for id in 1...3000 {
      mailbox.push(.updateShortSentMessage(.init(id: Int32(id), pts: 1, ptsCount: 1, date: 1)))
    }
    var ids: [Int32] = []
    while mailbox.metrics().depth > 0 {
      ids += mailbox.drain(limit: 257).entries.compactMap {
        if case .updateShortSentMessage(let value) = $0.updates { value.id } else { nil }
      }
    }
    #expect(ids == Array(1...3000).map(Int32.init))
  }

  @Test func backfillHandlesMaximumMessageIDWithoutOverflow() async throws {
    let coverage = try await ChannelBackfill.read(topID: .max, cutoff: 0, floorID: .max - 101,
      fetch: { ids in
        #expect(ids == (Int32.max - 100)...(Int32.max - 1) || ids == Int32.max...Int32.max)
        return .init(updates: [], users: [], chats: [])
      }, handle: { _ in })
    #expect(coverage.pages == 2 && coverage.reachedFloor)
    let empty = try await ChannelBackfill.read(topID: .max, cutoff: 0, floorID: .max,
      fetch: { _ in Issue.record("No IDs above maximum"); return .init(updates: [], users: [], chats: []) },
      handle: { _ in })
    #expect(empty.pages == 0 && empty.reachedFloor)
    #expect(ChannelBackfill.floor(topID: .min, initialSnapshot: true, newestRetainedID: nil,
      initialMessageLimit: .max) == 0)
    let minimumFloor = try await ChannelBackfill.read(topID: 1, cutoff: 0, floorID: .min,
      fetch: { ids in #expect(ids == 1...1); return .init(updates: [], users: [], chats: []) }, handle: { _ in })
    #expect(minimumFloor.pages == 1)
  }

  @Test(arguments: ["PERSISTENT_TIMESTAMP_INVALID", "PERSISTENT_TIMESTAMP_EMPTY"])
  func resetsOnlyExactClientPositionFailures(_ message: String) {
    #expect(ChannelState.rejectsStoredPTS(MTProtoRPCError(code: 400, message: message)))
    #expect(!ChannelState.rejectsStoredPTS(MTProtoRPCError(code: 500, message: message)))
    #expect(!ChannelState.rejectsStoredPTS(MTProtoRPCError(code: 500, message: "PERSISTENT_TIMESTAMP_OUTDATED")))
    #expect(!ChannelState.rejectsStoredPTS(MTProtoRPCError(code: 400, message: "PERSISTENT_TIMESTAMP_UNKNOWN")))
  }

  @Test func scheduleHonorsInjectedIntervalsAndRemoval() {
    let now = ContinuousClock.now
    var schedule = RecoverySchedule(accountInterval: .seconds(7), now: now, safetySeconds: { 13 })
    schedule.recovered(1, timeout: nil, now: now)
    #expect(schedule.channels[1] == now.advanced(by: .seconds(13)))
    schedule.recovered(2, timeout: 0, now: now)
    #expect(schedule.channels[2] == now.advanced(by: .seconds(1)))
    schedule.accountAdvanced(now: now)
    #expect(schedule.account == now.advanced(by: .seconds(7)))
    schedule.remove(1)
    #expect(schedule.due([2, 1], now: now) == [1])
  }

  @Test func coalescedSnapshotsIgnoreStaleRevisionsAndRetryFailedWrites() async throws {
    actor Store {
      var values: [Int] = []
      var fail = true
      func write(_ value: Int) throws {
        if fail { fail = false; throw CancellationError() }
        values.append(value)
      }
    }
    let store = Store()
    let writer = CheckpointWriter(saved: 0) { try await store.write($0) }
    await writer.update(0, revision: 1)
    try await writer.flush()
    #expect(await writer.writes == 0)
    await writer.update(1, revision: 2)
    await writer.update(2, revision: 3)
    await writer.update(1, revision: 2)
    await #expect(throws: CancellationError.self) { try await writer.flush() }
    try await writer.flush()
    #expect(await store.values == [2])
    #expect(await writer.writes == 1)
  }

  @Test func fileStoreUsesHexKeysAndReopensOpaqueBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileKeyValueStore(directory: directory)
    let key = "../key:☃"
    let file = directory.appendingPathComponent("2e2e2f6b65793ae29883.json")
    #expect(try await store.read(key: key) == nil)
    #expect(try await !store.exists(key: key))
    let bytes = Data([0, 255, 17])
    try await store.write(bytes, key: key)
    #expect(try Data(contentsOf: file) == bytes)
    let reopened = try FileKeyValueStore(directory: directory)
    #expect(try await reopened.read(key: key) == bytes)
    #expect(try await reopened.exists(key: key))
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
  }
}
