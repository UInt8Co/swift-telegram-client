import TelegramSchema

/// Where an update sits in Telegram's update sequences: the account's `pts`
/// and `qts`, or a channel's own `pts`.
///
/// A push that exactly continues the saved positions can be committed as it
/// is; only a gap, or a sequence not followed here, needs a difference call.
/// This is how TDLib avoids a round trip per push.
public enum UpdateSequence: Equatable, Sendable {
  case account(pts: Int32, count: Int32)
  case channel(Int64, pts: Int32, count: Int32)
  case qts(Int32)
  /// The account missed a channel's updates.
  case channelTooLong(Int64)
  /// Sequenced in a way not followed here, so it always asks for a difference.
  case unfollowed

  /// Nil for an update outside every sequence, such as a callback query.
  public static func of(_ update: TL.UpdateType) -> Self? {
    if case .updateChannelTooLong(let value) = update { return .channelTooLong(value.channelId) }
    guard let payload = Mirror(reflecting: update).children.first?.value else { return nil }
    var pts: Int32?
    var count: Int32?
    var qts: Int32?
    var channelID: Int64?
    for child in Mirror(reflecting: payload).children {
      switch child.label {
      case "pts": pts = child.value as? Int32
      case "ptsCount": count = child.value as? Int32
      case "qts": qts = child.value as? Int32
      case "channelId": channelID = child.value as? Int64
      default: continue
      }
    }
    if let qts { return pts == nil ? .qts(qts) : .unfollowed }
    guard let pts else { return nil }
    guard let count else { return .unfollowed }
    if let channel = channelID ?? ChannelUpdateFilter.sourceChannelID(of: update) {
      return .channel(channel, pts: pts, count: count)
    }
    return .account(pts: pts, count: count)
  }
}

/// One pushed container's sequenced content.
public struct PushSequence: Equatable, Sendable {
  /// `seq_start` and `seq` of an ordered container, and its date.
  public struct Order: Equatable, Sendable {
    public var start: Int32
    public var end: Int32
    public var date: Int32
    public init(start: Int32, end: Int32, date: Int32) {
      self.start = start
      self.end = end
      self.date = date
    }
  }
  public var seq: Order?
  public var updates: [UpdateSequence]
  /// False for a container that says updates were lost without saying which.
  public var complete: Bool

  public init(seq: Order? = nil, updates: [UpdateSequence] = [], complete: Bool = true) {
    self.seq = seq
    self.updates = updates
    self.complete = complete
  }

  public init(_ container: TL.UpdatesType) {
    switch container {
    case .updates(let value):
      self.init(
        seq: value.seq == 0 ? nil : .init(start: value.seq, end: value.seq, date: value.date),
        updates: value.updates.compactMap(UpdateSequence.of))
    case .updatesCombined(let value):
      self.init(
        seq: value.seq == 0 ? nil : .init(start: value.seqStart, end: value.seq, date: value.date),
        updates: value.updates.compactMap(UpdateSequence.of))
    case .updateShort(let value):
      self.init(updates: [UpdateSequence.of(value.update)].compactMap { $0 })
    case .updateShortMessage(let value):
      self.init(updates: [.account(pts: value.pts, count: value.ptsCount)])
    case .updateShortChatMessage(let value):
      self.init(updates: [.account(pts: value.pts, count: value.ptsCount)])
    case .updateShortSentMessage(let value):
      self.init(updates: [.account(pts: value.pts, count: value.ptsCount)])
    default: self.init(complete: false)
    }
  }
}

/// Saved update positions, advanced past pushes that continue them exactly.
public struct SequencePositions: Equatable, Sendable {
  public var account: UpdateCursor
  public var channels: [Int64: Int32]

  public init(account: UpdateCursor, channels: [Int64: Int32]) {
    self.account = account
    self.channels = channels
  }

  /// What still needs a difference call.
  public struct Gaps: Equatable, Sendable {
    public var account: Bool
    public var channels: Set<Int64>
    public init(account: Bool = false, channels: Set<Int64> = []) {
      self.account = account
      self.channels = channels
    }
    public var isEmpty: Bool { !account && channels.isEmpty }
  }

  /// Advances each position over the handled pushes that continue it, and
  /// reports the rest. A sequence with a gap keeps its old position, so a
  /// difference call from there replays everything after it. Pushes can
  /// arrive out of order, so those passed together are sorted first, and an
  /// update at or before a position counts as already applied.
  public mutating func advance(past pushes: [PushSequence]) -> Gaps {
    var gaps = Gaps()
    var accountUpdates: [(pts: Int32, count: Int32)] = []
    var qtsValues: [Int32] = []
    var channelUpdates: [Int64: [(pts: Int32, count: Int32)]] = [:]
    var orders: [PushSequence.Order] = []
    for push in pushes {
      if !push.complete { gaps.account = true }
      if let seq = push.seq { orders.append(seq) }
      for update in push.updates {
        switch update {
        case .account(let pts, let count): accountUpdates.append((pts, count))
        case .channel(let id, let pts, let count):
          channelUpdates[id, default: []].append((pts, count))
        case .qts(let value): qtsValues.append(value)
        case .channelTooLong(let id): gaps.channels.insert(id)
        case .unfollowed: gaps.account = true
        }
      }
    }
    func follow(_ entries: [(pts: Int32, count: Int32)], from start: Int32) -> Int32? {
      var position = start
      for entry in entries.sorted(by: { $0.pts < $1.pts }) where entry.pts > position {
        guard entry.pts - entry.count == position else { return nil }
        position = entry.pts
      }
      return position
    }
    if !gaps.account {
      var next = account
      if let pts = follow(accountUpdates, from: account.pts) {
        next.pts = pts
      } else {
        gaps.account = true
      }
      for value in qtsValues.sorted() where value > next.qts {
        guard value == next.qts + 1 else {
          gaps.account = true
          break
        }
        next.qts = value
      }
      for order in orders.sorted(by: { $0.start < $1.start }) where order.end > next.seq {
        guard order.start == next.seq + 1 else {
          gaps.account = true
          break
        }
        next.seq = order.end
        next.date = max(next.date, order.date)
      }
      if !gaps.account { account = next }
    }
    for (id, entries) in channelUpdates where !gaps.channels.contains(id) {
      guard let start = channels[id], let position = follow(entries, from: start) else {
        gaps.channels.insert(id)
        continue
      }
      channels[id] = position
    }
    return gaps
  }
}
