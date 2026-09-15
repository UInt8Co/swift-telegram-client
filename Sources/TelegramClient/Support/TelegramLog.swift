/// Where a client's diagnostics go, and how much of them. A line below
/// ``minimum`` is never built — the messages are `@autoclosure`, so the
/// per-request detail costs nothing while it is switched off.
public struct TelegramLog: Sendable {
  public enum Level: String, CaseIterable, Comparable, Sendable {
    case debug
    case info
    case warning
    case error

    var severity: Int {
      switch self {
      case .debug: 0
      case .info: 1
      case .warning: 2
      case .error: 3
      }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.severity < rhs.severity }
  }

  public let minimum: Level
  private let sink: @Sendable (Level, String) -> Void

  public init(minimum: Level = .info, sink: @escaping @Sendable (Level, String) -> Void) {
    self.minimum = minimum
    self.sink = sink
  }

  /// A log whose sink takes one already-rendered line. The level is spelled
  /// into it, because a sink that cannot see the level cannot show it.
  public init(minimum: Level = .info, lines: @escaping @Sendable (String) -> Void) {
    self.init(minimum: minimum) { level, message in lines("\(level.rawValue): \(message)") }
  }

  /// Drops everything. The default for the library's own entry points, so a
  /// caller that wants no output does not have to invent a sink.
  public static let silent = TelegramLog(minimum: .error) { _, _ in }

  public func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
  public func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
  public func warning(_ message: @autoclosure () -> String) { emit(.warning, message()) }
  public func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

  public func emit(_ level: Level, _ message: @autoclosure () -> String) {
    guard level >= minimum else { return }
    sink(level, message())
  }

  /// A plain line sink at one level, for the APIs that take a closure rather
  /// than a level — `MTProtoClient`'s own connection trace rides in at `debug`.
  /// `nil` when that level is switched off, so those APIs skip formatting too.
  public func lineSink(at level: Level) -> (@Sendable (String) -> Void)? {
    guard level >= minimum else { return nil }
    let sink = self.sink
    return { sink(level, $0) }
  }
}
