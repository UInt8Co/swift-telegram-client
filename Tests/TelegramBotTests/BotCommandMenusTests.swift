import Testing
import TelegramBot

@Suite struct BotCommandMenusTests {
  @Test func defaultCoalescesBehindOverride() async throws {
    let menus = BotCommandMenus<Int, String>(), sink = MenuSink(), user = 7
    let first = Task {
      try await menus.update(user: user, state: .override("first")) { try await sink.publish($0) }
    }
    try await eventually { await sink.waiter != nil }
    try await menus.update(user: user, state: .inheritDefault) { try await sink.publish($0) }
    await sink.resume()
    try await first.value
    #expect(await sink.languages == [.override("first"), .inheritDefault])
    try await menus.update(user: user, state: .inheritDefault) { try await sink.publish($0) }
    #expect(await sink.languages.count == 2)
  }

  @Test func uncertainWriteInvalidatesCachedDefault() async throws {
    let menus = BotCommandMenus<Int, String>(), sink = MenuSink(hold: false), user = 7
    try await menus.update(user: user, state: .inheritDefault) { try await sink.publish($0) }
    #expect(await sink.languages.isEmpty)
    await sink.failNext()
    await #expect(throws: MenuTestError.self) {
      try await menus.update(user: user, state: .override("first")) { try await sink.publish($0) }
    }
    try await menus.update(user: user, state: .inheritDefault) { try await sink.publish($0) }
    #expect(await sink.languages == [.inheritDefault])
  }

  @Test func latestOverrideWinsAndFailuresRetry() async throws {
    let menus = BotCommandMenus<Int, String>(), sink = MenuSink(), user = 7
    let first = Task {
      try await menus.update(user: user, state: .override("first")) { try await sink.publish($0) }
    }
    try await eventually { await sink.waiter != nil }
    try await menus.update(user: user, state: .override("second")) { try await sink.publish($0) }
    await sink.resume()
    try await first.value
    #expect(await sink.languages == [.override("first"), .override("second")])
    try await menus.update(user: user, state: .override("second")) { try await sink.publish($0) }
    #expect(await sink.languages.count == 2)
    await sink.failNext()
    await #expect(throws: MenuTestError.self) {
      try await menus.update(user: user, state: .inheritDefault) { try await sink.publish($0) }
    }
    try await menus.update(user: user, state: .inheritDefault) { try await sink.publish($0) }
    #expect(await sink.languages == [.override("first"), .override("second"), .inheritDefault])
  }
  @Test func defaultResetUsesDurableHintAfterRestartOrEviction() async throws {
    let menus = BotCommandMenus<Int, String>(cacheLimit: 0), sink = MenuSink(hold: false)
    try await menus.update(user: 1, state: .inheritDefault) { try await sink.publish($0) }
    #expect(await sink.languages.isEmpty)
    try await menus.update(user: 1, state: .inheritDefault, mayHaveOverride: true) { try await sink.publish($0) }
    try await menus.update(user: 1, state: .inheritDefault, mayHaveOverride: true) { try await sink.publish($0) }
    #expect(await sink.languages == [.inheritDefault, .inheritDefault])
  }

}

private actor MenuSink {
  var languages: [BotCommandMenuState<String>] = []
  var waiter: CheckedContinuation<Void, Never>?
  private var hold = true
  private var fail = false
  init(hold: Bool = true) { self.hold = hold }
  func publish(_ state: BotCommandMenuState<String>) async throws {
    if fail { fail = false; throw MenuTestError.offline }
    if hold { hold = false; await withCheckedContinuation { waiter = $0 } }
    languages.append(state)
  }
  func resume() { waiter?.resume(); waiter = nil }
  func failNext() { fail = true }
}

private enum MenuTestError: Error { case offline }
private func eventually(_ condition: () async -> Bool) async throws {
  for _ in 0..<10_000 {
    if await condition() { return }
    await Task.yield()
  }
  throw MenuTestError.offline
}
