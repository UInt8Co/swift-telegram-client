import Synchronization
import Testing

@testable import TelegramClient

@Suite struct TelegramLogTests {
  /// Collects what a log emitted, and how often it asked for a message at all.
  private final class Sink: Sendable {
    let lines = Mutex<[(TelegramLog.Level, String)]>([])
    let built = Mutex(0)

    var log: TelegramLog { log(minimum: .info) }

    func log(minimum: TelegramLog.Level) -> TelegramLog {
      TelegramLog(minimum: minimum) { level, message in
        self.lines.withLock { $0.append((level, message)) }
      }
    }

    /// A message whose construction is counted, to prove a dropped line is not
    /// formatted.
    func message(_ text: String) -> String {
      built.withLock { $0 += 1 }
      return text
    }
  }

  @Test func dropsEverythingBelowTheMinimumWithoutBuildingIt() {
    let sink = Sink()
    let log = sink.log
    log.debug(sink.message("per-poll detail"))
    log.info(sink.message("connected"))
    log.warning(sink.message("retrying"))
    log.error(sink.message("giving up"))

    #expect(sink.built.withLock { $0 } == 3)
    #expect(
      sink.lines.withLock { $0.map(\.0) } == [.info, .warning, .error])
    #expect(sink.lines.withLock { $0.map(\.1) } == ["connected", "retrying", "giving up"])
  }

  @Test func debugPassesEverythingThrough() {
    let sink = Sink()
    sink.log(minimum: .debug).debug(sink.message("per-poll detail"))
    #expect(sink.lines.withLock { $0.map(\.1) } == ["per-poll detail"])
  }

  @Test func aLineSinkIsNilBelowTheMinimumAndTaggedAboveIt() {
    let sink = Sink()
    #expect(sink.log.lineSink(at: .debug) == nil)
    sink.log.lineSink(at: .warning)?("wire")
    #expect(sink.lines.withLock { $0.map(\.0) } == [.warning])
  }

  @Test func aPlainLineSinkSpellsTheLevelIntoTheLine() {
    let lines = Mutex<[String]>([])
    let log = TelegramLog(minimum: .debug) { line in lines.withLock { $0.append(line) } }
    log.debug("polled")
    log.error("failed")
    #expect(lines.withLock { $0 } == ["debug: polled", "error: failed"])
  }

  @Test func levelsOrderBySeverity() {
    #expect(TelegramLog.Level.debug < .info)
    #expect(TelegramLog.Level.info < .warning)
    #expect(TelegramLog.Level.warning < .error)
    #expect(TelegramLog.Level.allCases.map(\.rawValue) == ["debug", "info", "warning", "error"])
  }
}
