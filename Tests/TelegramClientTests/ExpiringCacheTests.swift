import TelegramClient
import TelegramSchema
import Testing

@Suite("Expiring cache")
struct ExpiringCacheTests {
  @Test func sharesOneLookupAndHonorsInvalidation() async throws {
    let cache = ExpiringCache<Int, Int>(lifetime: .seconds(60))
    let loads = Counter()
    let gate = Gate()
    let callers = (0..<5).map { _ in
      Task {
        try await cache.value(for: 1) {
          await loads.increment()
          await gate.wait()
          return 7
        }
      }
    }
    await loads.waitUntil(1)
    await gate.open()
    for caller in callers { #expect(try await caller.value == 7) }
    #expect(await loads.value == 1)
    #expect(
      try await cache.value(for: 1) {
        await loads.increment()
        return 8
      } == 7)

    // An answer loaded across an invalidation is returned but not kept.
    let stale = Gate()
    let pending = Task {
      try await cache.value(for: 2) {
        await stale.wait()
        return 1
      }
    }
    try await Task.sleep(for: .milliseconds(20))
    await cache.invalidate(2)
    await stale.open()
    #expect(try await pending.value == 1)
    #expect(try await cache.value(for: 2) { 2 } == 2)

    struct Failure: Error {}
    await #expect(throws: Failure.self) { try await cache.value(for: 3) { throw Failure() } }
    #expect(try await cache.value(for: 3) { 3 } == 3)

    let short = ExpiringCache<Int, Int>(lifetime: .milliseconds(10))
    #expect(try await short.value(for: 1) { 1 } == 1)
    try await Task.sleep(for: .milliseconds(30))
    #expect(try await short.value(for: 1) { 2 } == 2)
  }

  @Test func conditionalInvalidationKeepsAnswersTheChangeConfirms() async throws {
    let cache = ExpiringCache<Int, Bool>(lifetime: .seconds(60))
    #expect(try await cache.value(for: 1) { true } == true)
    #expect(try await cache.value(for: 2) { false } == false)
    // Each is kept only while the change agrees with what is cached.
    await cache.invalidate(1) { $0 }
    await cache.invalidate(2) { $0 }
    #expect(try await cache.value(for: 1) { false } == true)
    #expect(try await cache.value(for: 2) { true } == true)
    await cache.invalidate { key, cached in key == 1 && cached == false }
    #expect(try await cache.value(for: 1) { false } == true)
    await cache.invalidate { key, cached in key == 1 && cached == true }
    #expect(try await cache.value(for: 1) { false } == false)
  }
}

private actor Counter {
  private(set) var value = 0
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  func increment() {
    value += 1
    waiters.removeAll { target, waiter in
      guard value >= target else { return false }
      waiter.resume()
      return true
    }
  }
  func waitUntil(_ target: Int) async {
    guard value < target else { return }
    await withCheckedContinuation { waiters.append((target, $0)) }
  }
}
private actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}
