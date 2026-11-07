import MTProtoClientKit
import Testing
@testable import TelegramClient

@Suite struct ExponentialRetryTests {
  @Test func operationResultSurvivesRetry() async throws {
    let attempts = Counter()
    let waits = Recorder()
    let value = try await ExponentialRetry.repeating(shouldRetry: ServerTransientFailure.describes, onRetry: { _, wait in waits.append(wait) },
                           sleep: { _ in }) {
      attempts.increment()
      guard attempts.count > 2 else { throw MTProtoRPCError(code: -503, message: "Timeout") }
      return "recovered"
    }
    #expect(value == "recovered")
    #expect(attempts.count == 3)
    #expect(waits.waits == [.seconds(1), .seconds(2)])
  }

  @Test func requestRefusalIsNotRetried() async {
    let attempts = Counter()
    // The retry gives up throwing after a few attempts, so a classifier that
    // wrongly swallowed this failure fails the test instead of spinning here.
    await #expect(throws: MTProtoRPCError(code: 400, message: "METHOD_INVALID")) {
      try await ExponentialRetry.repeating(shouldRetry: ServerTransientFailure.describes, sleep: { _ in }) {
        attempts.increment()
        guard attempts.count > 4 else { throw MTProtoRPCError(code: 400, message: "METHOD_INVALID") }
        return ()
      }
    }
    #expect(attempts.count == 1, "a refusal must not be retried behind a backoff")
  }

  @Test func cancellationIsNotSwallowedByTheRetry() async {
    let attempts = Counter()
    await #expect(throws: CancellationError.self) {
      try await ExponentialRetry.repeating(shouldRetry: ServerTransientFailure.describes, sleep: { _ in }) {
        attempts.increment()
        guard attempts.count > 4 else { throw CancellationError() }
        return ()
      }
    }
    #expect(attempts.count == 1)
  }

  /// The wait doubles and then holds at a minute: an outage is waited out
  /// without hammering an unavailable backend.
  @Test func theWaitDoublesAndThenHoldsAtAMinute() async throws {
    let attempts = Counter()
    let waits = Recorder()
    _ = try await ExponentialRetry.repeating(shouldRetry: ServerTransientFailure.describes, onRetry: { _, wait in waits.append(wait) },
                       sleep: { _ in }) {
      attempts.increment()
      guard attempts.count > 9 else { throw MTProtoClientError.timeout }
      return 0
    }
    #expect(waits.waits == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
                .seconds(32), .seconds(60), .seconds(60), .seconds(60)])
    #expect(ExponentialRetry.nextWait(after: ExponentialRetry.longestWait) == ExponentialRetry.longestWait)
  }

  private final class Counter {
    private(set) var count = 0
    func increment() { count += 1 }
  }

  private final class Recorder {
    private(set) var waits: [Duration] = []
    func append(_ wait: Duration) { waits.append(wait) }
  }

  @Test func customScheduleAndAttemptLimit() async {
    var attempts = 0
    var waits: [Duration] = []
    await #expect(throws: Failure.retry) {
      try await ExponentialRetry.repeating(firstWait: .milliseconds(10), longestWait: .milliseconds(25),
        maximumAttempts: 5, shouldRetry: { $0 is Failure },
        onRetry: { _, wait in waits.append(wait) }, sleep: { _ in }) {
        attempts += 1
        throw Failure.retry
      }
    }
    #expect(attempts == 5)
    #expect(waits == [.milliseconds(10), .milliseconds(20), .milliseconds(25), .milliseconds(25)])
  }

  @Test func cancellationOverridesPredicateAndSleepErrorsEscape() async {
    var attempts = 0
    await #expect(throws: CancellationError.self) {
      try await ExponentialRetry.repeating(shouldRetry: { _ in true }, sleep: { _ in Issue.record("Unexpected sleep") }) {
        attempts += 1
        throw CancellationError()
      }
    }
    #expect(attempts == 1)
    await #expect(throws: Failure.sleep) {
      try await ExponentialRetry.repeating(shouldRetry: { _ in true }, sleep: { _ in throw Failure.sleep }) {
        throw Failure.retry
      }
    }
  }

  private enum Failure: Error { case retry, sleep }

  private actor Owner {
    var attempts = 0
    final class Value { let number = 7 }
    func run() async throws {
      let value = try await ExponentialRetry.repeating(shouldRetry: { _ in true }, sleep: { _ in }) {
        self.attempts += 1
        if self.attempts < 2 { throw Failure.retry }
        return Value()
      }
      #expect(value.number == 7)
      #expect(attempts == 2)
    }
  }

  @Test func preservesCallerIsolationAndNonSendableResult() async throws {
    try await Owner().run()
  }
}
