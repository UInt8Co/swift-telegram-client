import TelegramSchema

/// What one difference carried — a channel's own or the account's — counted for
/// one channel.
///
/// A client that is being told nothing and one that is watching the wrong
/// channel both see no updates; these are the numbers that tell the two apart,
/// which is why they are worth keeping even though nothing acts on them.
public struct DifferenceReading: Equatable, Sendable, CustomStringConvertible {
  public var updates: Int
  public var forSource: Int
  public var channelTooLong: Bool
  public var otherChannels: Set<Int64>
  public var kinds: [String: Int]
  public var hasMore: Bool

  public init(
    updates: Int, forSource: Int, channelTooLong: Bool = false,
    otherChannels: Set<Int64> = [], kinds: [String: Int] = [:], hasMore: Bool = false
  ) {
    self.updates = updates
    self.forSource = forSource
    self.channelTooLong = channelTooLong
    self.otherChannels = otherChannels
    self.kinds = kinds
    self.hasMore = hasMore
  }

  /// True when there is nothing an operator would want to read about.
  public var isQuiet: Bool { updates == 0 && !hasMore }

  public var description: String {
    var parts = ["\(updates) update(s)", "\(forSource) for the source"]
    if channelTooLong { parts.append("the source needs a channel difference") }
    if !otherChannels.isEmpty {
      let ids = otherChannels.sorted().map(String.init).joined(separator: ", ")
      parts.append("other channel(s) \(ids)")
    }
    if !kinds.isEmpty {
      parts.append(
        kinds.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }
          .joined(separator: ", "))
    }
    if hasMore { parts.append("more to page") }
    return parts.joined(separator: "; ")
  }
}

extension ChannelUpdateFilter {
  /// Reads one page of updates for diagnostics, whichever difference it came
  /// from.
  public static func reading(
    _ updates: [TL.UpdateType], forChannelID channelID: Int64, hasMore: Bool
  ) -> DifferenceReading {
    var kinds: [String: Int] = [:]
    var otherChannels: Set<Int64> = []
    var forSource = 0
    var channelTooLong = false
    for update in updates {
      kinds[kind(of: update), default: 0] += 1
      if let id = sourceChannelID(of: update) {
        if id == channelID { forSource += 1 } else { otherChannels.insert(id) }
      }
      if case .updateChannelTooLong(let value) = update {
        if value.channelId == channelID {
          channelTooLong = true
        } else {
          otherChannels.insert(value.channelId)
        }
      }
    }
    return DifferenceReading(
      updates: updates.count, forSource: forSource, channelTooLong: channelTooLong,
      otherChannels: otherChannels, kinds: kinds, hasMore: hasMore)
  }

  /// The name of an update's constructor, for log lines and counters. Reflecting
  /// the generated enum's case name keeps this in step with a schema that grows
  /// an update kind; a hand-written switch would not.
  public static func kind(of update: TL.UpdateType) -> String {
    String(String(describing: update).prefix { $0 != "(" })
  }
}


extension ChannelUpdateFilter {
  /// The channel an update is a hint about: one whose message changed, or one
  /// `updateChannelTooLong` names.
  public static func hintedChannelID(of update: TL.UpdateType) -> Int64? {
    if case .updateChannelTooLong(let value) = update { return value.channelId }
    return sourceChannelID(of: update)
  }
}
