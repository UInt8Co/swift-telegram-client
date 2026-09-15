import MTProtoClientKit
import TelegramSchema

/// What one `updates.getChannelDifference` carried. A channel keeps its own
/// `pts`: the account difference never replays its posts, it only hints with
/// `updateChannelTooLong` (<https://corefork.telegram.org/api/updates>).
public struct ChannelDifferenceBatch: Equatable, Sendable {
  public var updates: [TL.UpdateType]
  public var users: [TL.UserType]
  public var chats: [TL.ChatType]
  /// The `pts` to resume from, or nil when the server named none and it has to
  /// be read back with `channels.getFullChannel`.
  public var pts: Int32?
  /// False while more pages are waiting; the caller keeps asking.
  public var isFinal: Bool
  /// Seconds the server asks the caller to wait before polling again.
  public var timeout: Int32?
  /// `channelDifferenceTooLong`: `updates` carries only the latest messages;
  /// the caller must enumerate history or record the skipped gap.
  public var skippedGap: Bool
  /// The latest message id at the position a too-long difference describes.
  /// A caller can use it to enumerate channel history with `channels.getMessages`.
  public var topMessageID: Int32?

  public init(
    updates: [TL.UpdateType], users: [TL.UserType], chats: [TL.ChatType], pts: Int32?,
    isFinal: Bool, timeout: Int32? = nil, skippedGap: Bool = false,
    topMessageID: Int32? = nil
  ) {
    self.updates = updates
    self.users = users
    self.chats = chats
    self.pts = pts
    self.isFinal = isFinal
    self.timeout = timeout
    self.skippedGap = skippedGap
    self.topMessageID = topMessageID
  }
}

public enum ChannelDifferenceDecoder {
  /// Reads a channel difference into a batch the importer can send. Messages
  /// become `updateNewChannelMessage` with a zero `pts`: the channel's position
  /// is the batch's, not one per update.
  public static func decode(_ difference: TL.Updates.ChannelDifferenceType)
    -> ChannelDifferenceBatch
  {
    switch difference {
    case .channelDifferenceEmpty(let empty):
      return ChannelDifferenceBatch(
        updates: [], users: [], chats: [], pts: empty.pts, isFinal: empty.final,
        timeout: empty.timeout)
    case .channelDifference(let difference):
      return ChannelDifferenceBatch(
        updates: messageUpdates(difference.newMessages) + difference.otherUpdates,
        users: difference.users, chats: difference.chats, pts: difference.pts,
        isFinal: difference.final, timeout: difference.timeout)
    case .channelDifferenceTooLong(let tooLong):
      // The dialog carries the channel's current position; without it the
      // caller has to ask `channels.getFullChannel` for it.
      var pts: Int32?
      var topMessageID: Int32?
      if case .dialog(let dialog) = tooLong.dialog {
        pts = dialog.pts
        topMessageID = dialog.topMessage
      }
      return ChannelDifferenceBatch(
        updates: messageUpdates(tooLong.messages), users: tooLong.users,
        chats: tooLong.chats, pts: pts, isFinal: tooLong.final, timeout: tooLong.timeout,
        skippedGap: true, topMessageID: topMessageID)
    }
  }

  private static func messageUpdates(_ messages: [TL.MessageType]) -> [TL.UpdateType] {
    messages.map {
      .updateNewChannelMessage(TL.UpdateNewChannelMessage(message: $0, pts: 0, ptsCount: 0))
    }
  }
}

public struct ChannelHistoryPage: Equatable, Sendable {
  public var updates: [TL.UpdateType]
  public var users: [TL.UserType]
  public var chats: [TL.ChatType]

  public init(
    updates: [TL.UpdateType], users: [TL.UserType], chats: [TL.ChatType]
  ) {
    self.updates = updates
    self.users = users
    self.chats = chats
  }
}

public enum ChannelHistoryDecoder {
  /// Converts exact-id history reads into oldest-first channel updates.
  public static func decode(
    _ result: TL.Messages.MessagesType, forChannelID channelID: Int64
  ) -> ChannelHistoryPage {
    let messages: [TL.MessageType]
    let users: [TL.UserType]
    let chats: [TL.ChatType]
    switch result {
    case .messages(let page):
      (messages, users, chats) = (page.messages, page.users, page.chats)
    case .messagesSlice(let page):
      (messages, users, chats) = (page.messages, page.users, page.chats)
    case .channelMessages(let page):
      (messages, users, chats) = (page.messages, page.users, page.chats)
    case .messagesNotModified:
      (messages, users, chats) = ([], [], [])
    }
    let updates: [TL.UpdateType] = messages.sorted {
      messageID($0) < messageID($1)
    }.compactMap { message -> TL.UpdateType? in
      if case .messageEmpty = message { return nil }
      return TL.UpdateType.updateNewChannelMessage(
        TL.UpdateNewChannelMessage(message: message, pts: 0, ptsCount: 0))
    }
    return ChannelHistoryPage(
      updates: ChannelUpdateFilter.updates(updates, forChannelID: channelID),
      users: users, chats: chats)
  }

  private static func messageID(_ message: TL.MessageType) -> Int32 {
    switch message {
    case .message(let value): value.id
    case .messageService(let value): value.id
    case .messageEmpty(let value): value.id
    }
  }
}

public enum ChannelState {
  /// The channel's current `pts`, which is where a reader with no history to
  /// catch up on starts.
  public static func pts(
    of channel: ChannelReference, using api: TLClient
  ) async throws -> Int32 {
    let full = try await api.invoke(
      TL.Channels.GetFullChannel(channel: channel.inputChannel))
    guard case .channelFull(let channelFull) = full.fullChat else {
      throw TelegramClientError.channelRequired(String(channel.id))
    }
    return channelFull.pts
  }

  /// True for the `PERSISTENT_TIMESTAMP_*` errors, which all mean the same
  /// thing: the `pts` being asked from is not one the server can serve.
  public static func rejectsStoredPTS(_ error: any Error) -> Bool {
    guard let rpc = error as? MTProtoRPCError else { return false }
    return rpc.message.hasPrefix("PERSISTENT_TIMESTAMP_")
  }
}

public enum ChannelDifferenceError: Error, Equatable, Sendable, CustomStringConvertible {
  case everyPositionRejected(Int64)
  case backfillSnapshotUnavailable(Int64)
  /// Update after update in a form this build has no schema for: the service has
  /// moved on and this build has not. Every one of them was stepped over first,
  /// so this is a channel that is unreadable rather than an update that is.
  case sourceUnreadable(Int64, Int32)

  public var description: String {
    switch self {
    case .everyPositionRejected(let channelID):
      "channel \(channelID) refused every position offered for its difference"
    case .backfillSnapshotUnavailable(let channelID):
      "channel \(channelID) did not provide a backfill snapshot"
    case .sourceUnreadable(let channelID, let pts):
      "channel \(channelID) has sent nothing this build can read since pts \(pts); it is "
        + "ahead of this build's schema"
    }
  }
}
