import TelegramBot
import Testing

@Suite struct DraftStreamTests {
  @Test func defaultPolicyAndIdleInputs() {
    let policy = DraftStreamPolicy()
    #expect(policy.inactivity == .seconds(20))
    #expect(policy.minimumDraftInterval == .zero)
    #expect(policy.keepAlive == .seconds(20))
    #expect(policy.maximumLifetime == .seconds(120))
    var stream = DraftStream()
    #expect(stream.next(at: .zero) == .idle)
    stream.stopped(at: .zero)
    stream.full(at: .zero)
    stream.settled(at: .zero)
    #expect(!stream.isClosing)
    #expect(stream.next(at: .seconds(100)) == .idle)
  }

  @Test func everyChangeIsDraftedAtOnceByDefault() {
    var stream = DraftStream()
    stream.changed(at: .zero)
    #expect(stream.next(at: .zero) == .showDraft)
    #expect(stream.next(at: .zero) == .wait(until: .seconds(20)))
    stream.changed(at: .milliseconds(10))
    stream.changed(at: .milliseconds(20))
    #expect(stream.next(at: .milliseconds(20)) == .showDraft)
    #expect(stream.next(at: .milliseconds(20)) == .wait(until: .milliseconds(20_020)))
    stream.changed(at: .milliseconds(30))
    #expect(stream.next(at: .milliseconds(30)) == .showDraft)
  }

  @Test func rapidChangesCollapseAndDraftAttemptsAreThrottled() {
    var stream = DraftStream(policy: .init(minimumDraftInterval: .milliseconds(1500)))
    stream.changed(at: .zero)
    #expect(stream.next(at: .zero) == .showDraft)
    #expect(stream.next(at: .zero) == .wait(until: .seconds(20)))
    stream.changed(at: .milliseconds(100))
    stream.changed(at: .seconds(1))
    #expect(stream.next(at: .seconds(1)) == .wait(until: .milliseconds(1500)))
    #expect(stream.next(at: .milliseconds(1499)) == .wait(until: .milliseconds(1500)))
    #expect(stream.next(at: .milliseconds(1500)) == .showDraft)
    #expect(stream.next(at: .milliseconds(1500)) == .wait(until: .seconds(21)))
    stream.changed(at: .seconds(2))
    #expect(stream.next(at: .seconds(3)) == .showDraft)
  }

  @Test func keepAliveDoesNotExtendInactivityOrLifetime() {
    var stream = DraftStream(policy: .init(inactivity: .seconds(60), keepAlive: .seconds(20)))
    stream.changed(at: .zero)
    #expect(stream.next(at: .zero) == .showDraft)
    #expect(stream.next(at: .seconds(19)) == .wait(until: .seconds(20)))
    #expect(stream.next(at: .seconds(20)) == .showDraft)
    #expect(stream.next(at: .seconds(40)) == .showDraft)
    #expect(stream.next(at: .seconds(60)) == .settle(.inactivity))
    #expect(stream.isClosing)
    stream.changed(at: .seconds(61))
    #expect(stream.next(at: .seconds(61)) == .settle(.inactivity))
  }

  @Test func keepAliveRespectsMinimumDraftInterval() {
    var stream = DraftStream(
      policy: .init(minimumDraftInterval: .seconds(5), keepAlive: .seconds(1)))
    stream.changed(at: .zero)
    #expect(stream.next(at: .zero) == .showDraft)
    #expect(stream.next(at: .seconds(1)) == .wait(until: .seconds(5)))
    #expect(stream.next(at: .seconds(5)) == .showDraft)
  }

  @Test func changesExtendInactivityButNeverMaximumLifetime() {
    var stream = DraftStream(policy: .init(inactivity: .seconds(10), maximumLifetime: .seconds(25)))
    stream.changed(at: .zero)
    #expect(stream.next(at: .zero) == .showDraft)
    for second in [9, 18, 24] {
      stream.changed(at: .seconds(second))
      #expect(stream.next(at: .seconds(second)) == .showDraft)
    }
    #expect(stream.next(at: .seconds(24)) == .wait(until: .seconds(25)))
    #expect(stream.next(at: .seconds(25)) == .settle(.lifetime))
  }

  @Test func earliestExpiryWinsAndLifetimeBreaksTies() {
    for (inactivity, lifetime, expected): (Int, Int, DraftSettleReason) in [
      (20, 120, .inactivity), (120, 20, .lifetime), (20, 20, .lifetime),
      (0, 20, .inactivity), (20, 0, .lifetime), (0, 0, .lifetime),
    ] {
      var stream = DraftStream(
        policy: .init(inactivity: .seconds(inactivity), maximumLifetime: .seconds(lifetime)))
      stream.changed(at: .seconds(10))
      #expect(stream.next(at: .seconds(200)) == .settle(expected))
    }
  }

  @Test func stopAndFullOverrideDeadlinesAndFirstExplicitReasonWins() {
    for fullFirst in [false, true] {
      var stream = DraftStream()
      stream.changed(at: .zero)
      if fullFirst { stream.full(at: .seconds(100)) } else { stream.stopped(at: .seconds(100)) }
      stream.stopped(at: .seconds(100))
      stream.full(at: .seconds(100))
      #expect(stream.next(at: .seconds(100)) == .settle(fullFirst ? .full : .stopped))
      stream.settled(at: .seconds(100))
      #expect(stream.next(at: .seconds(100)) == .idle)
      stream.changed(at: .seconds(100))
      #expect(stream.next(at: .seconds(100)) == .showDraft)
      #expect(stream.next(at: .seconds(119)) == .wait(until: .seconds(120)))
      #expect(stream.next(at: .seconds(120)) == .settle(.inactivity))
    }
  }
}
