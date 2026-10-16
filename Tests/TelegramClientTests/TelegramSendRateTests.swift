import MTProtoClientKit
import Synchronization
import Testing

@testable import TelegramClient

@Suite struct TelegramSendRateTests {
  /// Time that passes only when a wait is served, so a schedule is exact.
  final class VirtualClock: Sendable {
    private let offset = Mutex(Duration.zero)
    var now: Duration { offset.withLock { $0 } }
    func advance(_ duration: Duration) { offset.withLock { $0 += duration } }
  }

  private static func rate(_ limits: [TelegramSendRate.Limit], clock: VirtualClock) -> TelegramSendRate {
    TelegramSendRate(limits: limits, now: { clock.now }, sleep: { clock.advance($0) })
  }

  private static func floodWait(_ seconds: Int) -> MTProtoRPCError {
    MTProtoRPCError(code: 420, message: "FLOOD_WAIT_\(seconds)")
  }

  @Test("a per-minute budget waits for its oldest write to age out")
  func perMinuteBudget() async throws {
    let clock = VirtualClock()
    let rate = Self.rate([.perMinute(3)], clock: clock)
    for _ in 0..<3 { try await rate.reserve(account: 1, chat: 9, label: "test") }
    #expect(clock.now == .zero)
    try await rate.reserve(account: 1, chat: 9, label: "test")
    #expect(clock.now == .seconds(60))
  }

  @Test("a short burst window spaces writes long before the minute is spent")
  func burstWindow() async throws {
    let clock = VirtualClock()
    let rate = Self.rate([.init(3, per: .seconds(3)), .perMinute(20)], clock: clock)
    var times: [Duration] = []
    for _ in 0..<7 {
      try await rate.reserve(account: 1, chat: 9, label: "test")
      times.append(clock.now)
    }
    #expect(times == [.zero, .zero, .zero, .seconds(3), .seconds(3), .seconds(3), .seconds(6)])
  }

  @Test("chats and accounts keep separate budgets")
  func separateBudgets() async throws {
    let clock = VirtualClock()
    let rate = Self.rate([.perMinute(1)], clock: clock)
    try await rate.reserve(account: 1, chat: 9, label: "test")
    try await rate.reserve(account: 1, chat: 10, label: "test")
    try await rate.reserve(account: 2, chat: 9, label: "test")
    #expect(clock.now == .zero)
  }

  @Test("a request that posts several messages books that many slots")
  func weightedCost() async throws {
    let clock = VirtualClock()
    let rate = Self.rate([.init(4, per: .seconds(4))], clock: clock)
    try await rate.reserve(account: 1, chat: 9, label: "test")
    try await rate.reserve(account: 1, chat: 9, label: "test")
    try await rate.reserve(account: 1, chat: 9, cost: 3, label: "test")
    #expect(clock.now == .seconds(4))
    // Larger than the whole window: waits for it to empty, then books it all.
    try await rate.reserve(account: 1, chat: 9, cost: 10, label: "test")
    #expect(clock.now == .seconds(8))
    try await rate.reserve(account: 1, chat: 9, label: "test")
    #expect(clock.now == .seconds(12))
  }

  @Test("a hold keeps every writer off the chat, and a shorter one never shortens it")
  func holds() async throws {
    let clock = VirtualClock()
    let rate = Self.rate([.perMinute(20)], clock: clock)
    await rate.hold(account: 1, chat: 9, for: .seconds(5))
    await rate.hold(account: 1, chat: 9, for: .seconds(2))
    #expect(await rate.remainingHold(account: 1, chat: 9) == .seconds(5))
    #expect(await rate.remainingHold(account: 1, chat: 10) == nil)
    try await rate.reserve(account: 1, chat: 9, label: "test")
    #expect(clock.now == .seconds(5))
    #expect(await rate.remainingHold(account: 1, chat: 9) == nil)
  }

  @Test("a short flood wait is served in place and the same send repeated")
  func shortFloodWaitServedInPlace() async throws {
    let clock = VirtualClock()
    let rate = Self.rate([.perMinute(20)], clock: clock)
    let attempts = Mutex(0)
    let value = try await rate.send(account: 1, chat: 9, label: "test") {
      let attempt = attempts.withLock { count in
        count += 1
        return count
      }
      if attempt == 1 { throw Self.floodWait(3) }
      return "sent"
    }
    #expect(value == "sent")
    #expect(attempts.withLock { $0 } == 2)
    #expect(clock.now == .seconds(4))
  }

  @Test("a long flood wait is rethrown and still holds the chat")
  func longFloodWaitRethrown() async throws {
    let clock = VirtualClock()
    let rate = Self.rate([.perMinute(20)], clock: clock)
    await #expect(throws: MTProtoRPCError.self) {
      try await rate.send(account: 1, chat: 9, label: "test", longestWait: .seconds(10)) {
        throw Self.floodWait(30)
      }
    }
    #expect(clock.now == .zero)
    #expect(await rate.remainingHold(account: 1, chat: 9) == .seconds(31))
  }

  @Test("other failures pass through without a hold or a retry")
  func otherFailuresPassThrough() async throws {
    let clock = VirtualClock()
    let rate = Self.rate([.perMinute(20)], clock: clock)
    let attempts = Mutex(0)
    await #expect(throws: MTProtoRPCError.self) {
      try await rate.send(account: 1, chat: 9, label: "test") {
        attempts.withLock { $0 += 1 }
        throw MTProtoRPCError(code: 400, message: "PEER_ID_INVALID")
      }
    }
    #expect(attempts.withLock { $0 } == 1)
    #expect(await rate.remainingHold(account: 1, chat: 9) == nil)
  }
}
