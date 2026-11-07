import Synchronization
import TelegramBot
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

private struct StreamInstant: InstantProtocol {
  let offset: Duration
  func advanced(by duration: Duration) -> Self { .init(offset: offset + duration) }
  func duration(to other: Self) -> Duration { other.offset - offset }
  static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
}

private final class StreamClock: Clock, Sendable {
  private struct State {
    var now = StreamInstant(offset: .zero)
    var sleepers: [UUID: (StreamInstant, CheckedContinuation<Void, any Error>)] = [:]
  }
  private let state = Mutex(State())
  var now: StreamInstant { state.withLock { $0.now } }
  var minimumResolution: Duration { .nanoseconds(1) }
  var deadlines: [StreamInstant] { state.withLock { $0.sleepers.values.map { $0.0 } } }

  func advance(by duration: Duration) {
    let ready = state.withLock { state in
      state.now = state.now.advanced(by: duration)
      let ready = state.sleepers.filter { $0.value.0 <= state.now }
      for id in ready.keys { state.sleepers.removeValue(forKey: id) }
      return ready.values.map { $0.1 }
    }
    for continuation in ready { continuation.resume() }
  }

  func sleep(until deadline: StreamInstant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) -> Void in
        enum Outcome { case cancelled, due, waiting }
        let outcome = state.withLock { (state: inout State) -> Outcome in
          if Task.isCancelled { return .cancelled }
          if deadline <= state.now { return .due }
          state.sleepers[id] = (deadline, continuation)
          return .waiting
        }
        switch outcome {
        case .cancelled: continuation.resume(throwing: CancellationError())
        case .due: continuation.resume()
        case .waiting: break
        }
      }
    } onCancel: {
      let continuation = self.state.withLock { $0.sleepers.removeValue(forKey: id)?.1 }
      continuation?.resume(throwing: CancellationError())
    }
  }
}

private enum StreamTestError: Error { case draft, settlement, timeout }

private actor StreamTransport: DraftStreamTransport {
  struct Call: Sendable, Equatable {
    let key: String
    let id: Int64
    let operation: DraftStreamOperation
  }
  var calls: [Call] = []
  var completed: [Call] = []
  var maximumActive = 0
  var overlap = false
  private var active: Set<String> = []
  private var heldDrafts: Set<String>
  private var heldSettlements: Set<String>
  private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
  private let failDrafts: Bool
  private let failSettlements: Bool

  init(
    heldDrafts: Set<String> = [], heldSettlements: Set<String> = [],
    failDrafts: Bool = false, failSettlements: Bool = false
  ) {
    self.heldDrafts = heldDrafts
    self.heldSettlements = heldSettlements
    self.failDrafts = failDrafts
    self.failSettlements = failSettlements
  }

  func showDraft(for key: String, draftID: Int64) async throws {
    await perform(
      .init(key: key, id: draftID, operation: .showDraft), hold: heldDrafts.remove(key) != nil)
    if failDrafts { throw StreamTestError.draft }
  }

  func settle(_ key: String, draftID: Int64, reason: DraftSettleReason) async throws {
    await perform(
      .init(key: key, id: draftID, operation: .settle(reason)),
      hold: heldSettlements.remove(key) != nil)
    if failSettlements { throw StreamTestError.settlement }
  }

  private func perform(_ call: Call, hold: Bool) async {
    if !active.insert(call.key).inserted { overlap = true }
    maximumActive = max(maximumActive, active.count)
    calls.append(call)
    if hold { await withCheckedContinuation { waiters[call.key] = $0 } }
    active.remove(call.key)
    completed.append(call)
  }

  func release(_ key: String) { waiters.removeValue(forKey: key)?.resume() }
}

private func eventually(_ condition: () async -> Bool) async throws {
  let limit = ContinuousClock.now.advanced(by: .seconds(5))
  while !(await condition()) {
    guard ContinuousClock.now < limit else { throw StreamTestError.timeout }
    await Task.yield()
  }
}

@Suite struct DraftStreamerTests {
  @Test func changedReturnsTheOwningGeneration() async throws {
    let transport = StreamTransport()
    let streamer = DraftStreamer(
      transport: transport, onError: { _, _, _, _ in Issue.record("Unexpected error") })
    let first = try #require(await streamer.changed("a"))
    #expect(await streamer.changed("a") == first)
    await streamer.full("a")
    let second = try #require(await streamer.changed("a"))
    #expect(first != second)
    await streamer.stop(draftID: second)
    let third = try #require(await streamer.changed("a"))
    #expect(third != first && third != second)
    await streamer.settleAll()
    #expect(await streamer.changed("a") == nil)
    #expect(await transport.calls.map(\.id) == [first, second, third])
  }

  @Test func injectedClockCoalescesRefreshesAndSettlesWithoutRealTimeDelays() async throws {
    let clock = StreamClock()
    let transport = StreamTransport()
    let streamer = DraftStreamer(
      transport: transport,
      policy: .init(inactivity: .seconds(50), minimumDraftInterval: .milliseconds(1500)),
      clock: clock,
      onError: { _, _, _, _ in Issue.record("Unexpected transport error") })
    let run = Task { await streamer.run() }
    defer { run.cancel() }
    await streamer.changed("a")
    try await eventually { await transport.completed.count == 1 }
    let first = try #require(await transport.calls.first)
    #expect(first.id != 0 && first.operation == .showDraft)
    clock.advance(by: .seconds(1))
    await streamer.changed("a")
    await streamer.changed("a")
    try await eventually { clock.deadlines.contains(.init(offset: .milliseconds(1500))) }
    #expect(await transport.calls.count == 1)
    clock.advance(by: .milliseconds(500))
    try await eventually { await transport.completed.count == 2 }
    try await eventually { clock.deadlines.contains(.init(offset: .milliseconds(21_500))) }
    clock.advance(by: .seconds(20))
    try await eventually { await transport.completed.count == 3 }
    clock.advance(by: .milliseconds(29_500))
    try await eventually { await transport.completed.count == 4 }
    #expect(await transport.calls.last?.operation == .settle(.inactivity))
    #expect(await transport.calls.allSatisfy { $0.id == first.id })
    await streamer.settleAll()
    await run.value
  }

  @Test func realTimeDraftsCoalesceOnlyWhileARequestIsInFlight() async throws {
    let clock = StreamClock()
    let transport = StreamTransport(heldDrafts: ["a"])
    let streamer = DraftStreamer(
      transport: transport, clock: clock,
      onError: { _, _, _, _ in Issue.record("Unexpected transport error") })
    let run = Task { await streamer.run() }
    defer { run.cancel() }
    await streamer.changed("a")
    try await eventually { await transport.calls.count == 1 }
    // Three changes while the first draft is in flight: one follow-up, at once.
    await streamer.changed("a")
    await streamer.changed("a")
    await streamer.changed("a")
    #expect(await transport.calls.count == 1)
    await transport.release("a")
    try await eventually { await transport.completed.count == 2 }
    #expect(await transport.calls.map(\.operation) == [.showDraft, .showDraft])
    // No clock advance was needed, and nothing more is sent until the next change.
    await streamer.changed("a")
    try await eventually { await transport.completed.count == 3 }
    #expect(await !transport.overlap)
    await streamer.settleAll()
    await run.value
  }

  @Test func stopAndFullRollOverIDsAndOldStopsCannotCloseTheNextStream() async throws {
    let clock = StreamClock()
    let transport = StreamTransport(heldSettlements: ["a"])
    let streamer = DraftStreamer(
      transport: transport, clock: clock,
      onError: { _, _, _, _ in Issue.record("Unexpected transport error") })
    let run = Task { await streamer.run() }
    defer { run.cancel() }
    await streamer.changed("a")
    try await eventually { await transport.completed.count == 1 }
    let first = try #require(await transport.calls.first).id
    await streamer.stop(draftID: first)
    try await eventually { await transport.calls.count == 2 }
    await streamer.stop(draftID: first)
    await streamer.changed("a")
    await transport.release("a")
    try await eventually { await transport.completed.count == 3 }
    let second = try #require(await transport.calls.last).id
    #expect(second != first && second != 0)
    await streamer.stop(draftID: first)
    await streamer.stop(draftID: 0)
    await streamer.full("a")
    try await eventually { await transport.completed.count == 4 }
    #expect(
      await transport.calls.map(\.operation) == [
        .showDraft, .settle(.stopped), .showDraft, .settle(.full),
      ])
    #expect(await !transport.overlap)
    await streamer.settleAll()
    await run.value
  }

  @Test func changesDuringADraftArePreservedAndSettlementWaitsForIt() async throws {
    let clock = StreamClock()
    let transport = StreamTransport(heldDrafts: ["a"])
    let streamer = DraftStreamer(
      transport: transport, clock: clock,
      onError: { _, _, _, _ in Issue.record("Unexpected transport error") })
    let run = Task { await streamer.run() }
    defer { run.cancel() }
    await streamer.changed("a")
    try await eventually { await transport.calls.count == 1 }
    clock.advance(by: .seconds(2))
    await streamer.changed("a")
    await transport.release("a")
    try await eventually { await transport.completed.count == 2 }
    #expect(await transport.calls.map(\.operation) == [.showDraft, .showDraft])
    await streamer.settleAll()
    #expect(await transport.completed.last?.operation == .settle(.stopped))
    #expect(await !transport.overlap)
    await run.value
  }

  @Test func concurrencyIsBoundedWhileOtherKeysKeepMoving() async throws {
    let clock = StreamClock()
    let transport = StreamTransport(heldDrafts: ["a", "b", "c"])
    let streamer = DraftStreamer(
      transport: transport, clock: clock, maximumConcurrentCalls: 2,
      onError: { _, _, _, _ in Issue.record("Unexpected transport error") })
    for key in ["a", "b", "c"] { await streamer.changed(key) }
    let run = Task { await streamer.run() }
    defer { run.cancel() }
    try await eventually { await transport.calls.count == 2 }
    #expect(Set(await transport.calls.map(\.key)) == ["a", "b"])
    await streamer.full("a")
    await transport.release("b")
    try await eventually { await transport.calls.count == 3 }
    #expect(await transport.calls.last?.key == "c")
    await transport.release("a")
    try await eventually {
      await transport.completed.contains { $0.key == "a" && $0.operation == .settle(.full) }
    }
    await transport.release("c")
    await streamer.settleAll()
    #expect(await transport.maximumActive == 2)
    #expect(await !transport.overlap)
    #expect(
      await transport.calls.filter { if case .settle = $0.operation { true } else { false } }.count
        == 3)
    await run.value
  }

  @Test func failuresAreReportedAndDoNotStopSettlementOrOtherKeys() async throws {
    let clock = StreamClock()
    let transport = StreamTransport(failDrafts: true, failSettlements: true)
    let errors = Mutex<[DraftStreamOperation]>([])
    let streamer = DraftStreamer(
      transport: transport, clock: clock,
      onError: { _, _, operation, _ in errors.withLock { $0.append(operation) } })
    let run = Task { await streamer.run() }
    defer { run.cancel() }
    await streamer.changed("a")
    await streamer.changed("b")
    try await eventually { errors.withLock { $0.count == 2 } }
    clock.advance(by: .seconds(20))
    try await eventually { errors.withLock { $0.count == 4 } }
    await streamer.settleAll()
    #expect(errors.withLock { $0.filter { $0 == .showDraft }.count } == 2)
    #expect(errors.withLock { $0.filter { $0 == .settle(.inactivity) }.count } == 2)
    #expect(await transport.calls.count == 4)
    await run.value
  }

  @Test func shutdownDrainsWithoutRunAndIsIdempotent() async {
    let transport = StreamTransport()
    let streamer = DraftStreamer(
      transport: transport, maximumConcurrentCalls: 1,
      onError: { _, _, _, _ in Issue.record("Unexpected transport error") })
    await streamer.full("missing")
    await streamer.stop(draftID: 123)
    await streamer.changed("a")
    await streamer.full("a")
    await streamer.changed("a")
    await streamer.changed("b")
    await streamer.settleAll()
    await streamer.settleAll()
    await streamer.changed("ignored")
    let calls = await transport.calls
    #expect(calls.count == 3)
    #expect(Set(calls.map(\.id)).count == 3)
    #expect(calls.filter { $0.operation == .settle(.full) }.count == 1)
    #expect(calls.filter { $0.operation == .settle(.stopped) }.count == 2)
    #expect(await transport.maximumActive == 1)
    #expect(await !transport.overlap)
  }

  @Test func cancellationLeavesContentAvailableForExplicitShutdown() async throws {
    let clock = StreamClock()
    let transport = StreamTransport(heldDrafts: ["a"])
    let streamer = DraftStreamer(
      transport: transport, clock: clock,
      onError: { _, _, _, _ in Issue.record("Unexpected transport error") })
    let run = Task { await streamer.run() }
    await streamer.changed("a")
    try await eventually { await transport.calls.count == 1 }
    run.cancel()
    await run.value
    let drain = Task { await streamer.settleAll() }
    await transport.release("a")
    await drain.value
    #expect(await transport.calls.map(\.operation) == [.showDraft, .settle(.stopped)])
    #expect(await !transport.overlap)
  }
}
