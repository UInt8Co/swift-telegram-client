import TelegramSchema

public struct UpdateCursor: Codable, Equatable, Sendable {
  public var pts: Int32
  public var qts: Int32
  public var date: Int32
  public var seq: Int32

  public init(pts: Int32, qts: Int32, date: Int32, seq: Int32) {
    self.pts = pts
    self.qts = qts
    self.date = date
    self.seq = seq
  }

  public init(_ state: TL.Updates.State) {
    self.init(pts: state.pts, qts: state.qts, date: state.date, seq: state.seq)
  }

  public static let beginning = UpdateCursor(pts: 1, qts: 0, date: 1, seq: 0)
}

public struct DifferenceBatch: Equatable, Sendable {
  public var updates: [TL.UpdateType]
  public var users: [TL.UserType]
  public var chats: [TL.ChatType]
  public var cursor: UpdateCursor
  public var hasMore: Bool

  public init(
    updates: [TL.UpdateType], users: [TL.UserType], chats: [TL.ChatType],
    cursor: UpdateCursor, hasMore: Bool
  ) {
    self.updates = updates
    self.users = users
    self.chats = chats
    self.cursor = cursor
    self.hasMore = hasMore
  }
}

public enum DifferenceDecoder {
  public static func decode(
    _ difference: TL.Updates.DifferenceType, from cursor: UpdateCursor,
    sourceDescription: String
  ) throws -> DifferenceBatch {
    switch difference {
    case .differenceEmpty(let empty):
      return DifferenceBatch(
        updates: [], users: [], chats: [],
        cursor: UpdateCursor(
          pts: cursor.pts, qts: cursor.qts, date: empty.date, seq: empty.seq),
        hasMore: false)
    case .difference(let result):
      return batch(
        messages: result.newMessages, updates: result.otherUpdates,
        users: result.users, chats: result.chats,
        cursor: UpdateCursor(result.state), hasMore: false)
    case .differenceSlice(let result):
      return batch(
        messages: result.newMessages, updates: result.otherUpdates,
        users: result.users, chats: result.chats,
        cursor: UpdateCursor(result.intermediateState), hasMore: true)
    case .differenceTooLong:
      throw TelegramClientError.historyTooLong(sourceDescription)
    }
  }

  private static func batch(
    messages: [TL.MessageType], updates: [TL.UpdateType], users: [TL.UserType],
    chats: [TL.ChatType], cursor: UpdateCursor, hasMore: Bool
  ) -> DifferenceBatch {
    let messageUpdates = messages.map { message in
      if case .peerChannel = peer(of: message) {
        return TL.UpdateType.updateNewChannelMessage(
          TL.UpdateNewChannelMessage(message: message, pts: 0, ptsCount: 0))
      }
      return TL.UpdateType.updateNewMessage(
        TL.UpdateNewMessage(message: message, pts: 0, ptsCount: 0))
    }
    return DifferenceBatch(
      updates: messageUpdates + updates, users: users, chats: chats,
      cursor: cursor, hasMore: hasMore)
  }

  private static func peer(of message: TL.MessageType) -> TL.PeerType? {
    switch message {
    case .message(let value): value.peerId
    case .messageService(let value): value.peerId
    case .messageEmpty(let value): value.peerId
    }
  }
}

public enum ChannelUpdateFilter {
  public static func updates(_ updates: [TL.UpdateType], forChannelID channelID: Int64)
    -> [TL.UpdateType]
  {
    updates.filter { sourceChannelID(of: $0) == channelID }
  }

  /// The channel an update changes something in. A pin belongs here beside the
  /// message CRUD: it says a message that already arrived is now pinned.
  public static func sourceChannelID(of update: TL.UpdateType) -> Int64? {
    switch update {
    case .updateNewChannelMessage(let update): channelID(of: update.message)
    case .updateEditChannelMessage(let update): channelID(of: update.message)
    case .updateDeleteChannelMessages(let update): update.channelId
    case .updatePinnedChannelMessages(let update): update.channelId
    case .updateMessageReactions(let update):
      if case .peerChannel(let channel) = update.peer { channel.channelId } else { nil }
    default: nil
    }
  }

  private static func channelID(of message: TL.MessageType) -> Int64? {
    let peer: TL.PeerType?
    switch message {
    case .message(let message): peer = message.peerId
    case .messageService(let message): peer = message.peerId
    case .messageEmpty(let message): peer = message.peerId
    }
    guard case .peerChannel(let channel) = peer else { return nil }
    return channel.channelId
  }
}

extension Array {
  public func chunks(ofCount count: Int) -> [[Element]] {
    precondition(count > 0)
    var result: [[Element]] = []
    var index = startIndex
    while index != endIndex {
      let end = self.index(index, offsetBy: count, limitedBy: endIndex) ?? endIndex
      result.append(Array(self[index..<end]))
      index = end
    }
    return result
  }
}
