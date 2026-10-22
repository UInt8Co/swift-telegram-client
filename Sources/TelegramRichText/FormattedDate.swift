import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A point in time that each reader's Telegram app formats in their own
/// language and time zone. Apps that cannot format dates show the fallback
/// instead, which is also what ``RichMessage/text`` reports.
public struct FormattedDate: InlineContent {
  /// The parts the app shows. An empty format leaves the choice to the app.
  public struct Format: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Relative to now, such as “in 5 minutes” or “yesterday”.
    public static let relative = Format(rawValue: 1 << 0)
    /// Hours and minutes.
    public static let shortTime = Format(rawValue: 1 << 1)
    /// Hours, minutes and seconds.
    public static let longTime = Format(rawValue: 1 << 2)
    /// The date in numbers.
    public static let shortDate = Format(rawValue: 1 << 3)
    /// The date with the month's name.
    public static let longDate = Format(rawValue: 1 << 4)
    /// The name of the weekday.
    public static let dayOfWeek = Format(rawValue: 1 << 5)

    /// The date and the time to the minute.
    public static let dateTime: Format = [.shortDate, .shortTime]
  }

  public let date: Date
  public let format: Format
  public let fallback: Inline

  public init(_ date: Date, format: Format = [], fallback: some InlineContent) {
    self.date = date
    self.format = format
    self.fallback = Inline(fallback)
  }

  /// Falls back to the UTC date and time in ISO 8601 order, limited to the
  /// parts `format` asks for, such as `2026-10-20 14:03 UTC`.
  public init(_ date: Date, format: Format = []) {
    self.init(date, format: format, fallback: Text(Self.utc(date, format: format)))
  }

  public var richText: TL.RichTextType {
    // Whole seconds since 1970, rounded down; out-of-range dates are clamped.
    let seconds = date.timeIntervalSince1970.rounded(.down)
    let date: Int32 =
      seconds >= Double(Int32.max) ? .max : seconds <= Double(Int32.min) ? .min : Int32(seconds)
    return .textDate(
      .init(
        relative: format.contains(.relative), shortTime: format.contains(.shortTime),
        longTime: format.contains(.longTime), shortDate: format.contains(.shortDate),
        longDate: format.contains(.longDate), dayOfWeek: format.contains(.dayOfWeek),
        text: fallback.richText, date: date))
  }

  static func utc(_ date: Date, format: Format) -> String {
    let times: Format = [.relative, .shortTime, .longTime]
    let dates: Format = [.relative, .shortDate, .longDate, .dayOfWeek]
    let showsTime = format.isEmpty || !format.isDisjoint(with: times)
    let showsDate = format.isEmpty || !format.isDisjoint(with: dates)
    let iso = date.ISO8601Format()  // 2026-10-20T14:03:05Z
    let day = iso.prefix(10)
    let time = iso.dropFirst(11).prefix(format.contains(.longTime) ? 8 : 5)
    switch (showsDate, showsTime) {
    case (true, true): return "\(day) \(time) UTC"
    case (false, true): return "\(time) UTC"
    default: return String(day)
    }
  }
}
