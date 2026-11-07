import MTProtoClientKit
import Testing
@testable import TelegramClient

@Suite struct RequestLimiterTests {
  private actor Probe {
    var starts: [ContinuousClock.Instant] = []
    var active = 0
    var peak = 0
    func request() async throws {
      starts.append(.now); active += 1; peak = max(peak, active)
      defer { active -= 1 }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
  @Test func limiterSerializesAndPacesStarts() async throws {
    let probe = Probe(), limiter = RequestLimiter(interval: .milliseconds(30))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<4 { group.addTask { _ = try await limiter.run { try await probe.request() } } }
      try await group.waitForAll()
    }
    #expect(await probe.peak == 1)
    let times = await probe.starts
    #expect(times.count == 4)
    for index in 1..<times.count { #expect(times[index - 1].duration(to: times[index]) >= .milliseconds(29)) }
  }
  @Test func queuedCancellationDoesNotBlockLimiterAndFloodPausesNextRead() async throws {
    let limiter = RequestLimiter(interval: .zero)
    let started = AsyncStream<Void>.makeStream()
    let first = Task {
      try await limiter.run {
        started.continuation.yield(())
        try await Task.sleep(for: .milliseconds(50))
        throw MTProtoRPCError(code: 420, message: "FLOOD_WAIT_1")
      } as Void
    }
    for await _ in started.stream { break }
    let cancelled = Task { try await limiter.run { Issue.record("Cancelled queued read started") } }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    do { try await first.value; Issue.record("Flood swallowed") }
    catch { #expect(MTProtoDirective(error)?.wait != nil) }
    let before = ContinuousClock.now
    _ = try await limiter.run { 1 }
    #expect(before.duration(to: .now) >= .milliseconds(900))
  }

  @Test func multipleCapacityHoldersStillSpaceTheirStarts() async throws {
    let limiter = RequestLimiter(interval: .milliseconds(20), concurrencyLimit: 2)
    actor Probe {
      var active = 0
      var peak = 0
      var starts: [ContinuousClock.Instant] = []
      func run() async throws {
        active += 1
        peak = max(peak, active)
        starts.append(.now)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(80))
      }
    }
    let probe = Probe()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<5 { group.addTask { try await limiter.run { try await probe.run() } } }
      try await group.waitForAll()
    }
    #expect(await probe.peak == 2)
    let starts = await probe.starts
    for index in 1..<starts.count {
      #expect(starts[index - 1].duration(to: starts[index]) >= .milliseconds(19))
    }
  }
}
