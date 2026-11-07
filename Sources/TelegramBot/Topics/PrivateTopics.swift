import TelegramClient
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A private-topic operation could not produce a usable topic.
public enum PrivateTopicError: Error, Equatable {
  /// `messages.createForumTopic` answered without the topic's service message.
  case topicNotCreated
  /// A title is invalid; current client methods sanitize titles instead of throwing this case.
  case invalidTitle
}

/// Topics in a bot's private chat with a user, which @BotFather enables per
/// bot. Unlike supergroup topics, a private topic's ID is not the ID of the
/// service message that opened it: that message's reply header carries the
/// topic ID as `reply_to_top_id`, and so does every message in the topic. The
/// topic ID is the `top_msg_id` messages, drafts and replies in it carry.
public enum PrivateTopics {
  /// Whether @BotFather enabled topics in private chats for this bot account.
  public static func isEnabled(for bot: TL.User) -> Bool { bot.bot && bot.botForumView }

  /// The topic `messages.createForumTopic` opened in the chat with `user`:
  /// the `messageActionTopicCreate` service message, matched to `randomID`
  /// through `updateMessageID` when Telegram includes one.
  public static func createdTopicID(in updates: TL.UpdatesType, user: Int64, randomID: Int64)
    -> Int32?
  {
    let list: [TL.UpdateType]
    switch updates {
    case .updates(let value): list = value.updates
    case .updatesCombined(let value): list = value.updates
    case .updateShort(let value): list = [value.update]
    default: return nil
    }
    let assigned = list.compactMap { update -> Int32? in
      guard case .updateMessageID(let value) = update, value.randomId == randomID else {
        return nil
      }
      return value.id
    }.first
    let otherAssignments = Set(
      list.compactMap { update -> Int32? in
        guard case .updateMessageID(let value) = update, value.randomId != randomID else {
          return nil
        }
        return value.id
      })
    for update in list {
      guard case .updateNewMessage(let value) = update,
        case .messageService(let service) = value.message,
        case .messageActionTopicCreate = service.action,
        case .peerUser(let peer) = service.peerId, peer.userId == user
      else { continue }
      if let assigned {
        if assigned == service.id { return ForumTopics.createdTopicID(of: service) }
      } else if !otherAssignments.contains(service.id) {
        return ForumTopics.createdTopicID(of: service)
      }
    }
    return nil
  }

  /// The RPC error message Telegram sends when topic creation is turned off
  /// for this bot in @BotFather. It applies to every user, not one chat.
  public static let creationForbiddenError = "BOT_FORUM_CREATE_FORBIDDEN"

  /// RPC error messages meaning the bot cannot write to the user at all
  /// until they start or unblock it.
  public static func isUserUnreachable(errorMessage: String) -> Bool {
    [
      "USER_IS_BLOCKED", "INPUT_USER_DEACTIVATED", "USER_DEACTIVATED", "USER_DEACTIVATED_BAN",
      "PEER_ID_INVALID",
      "USER_BOT_INVALID", "BOT_CANNOT_INITIATE", "CHAT_WRITE_FORBIDDEN",
    ].contains(errorMessage)
  }
}

/// A topic the bot opened in a private chat, found by its creation message.
public struct CreatedPrivateTopic: Sendable, Hashable {
  /// The private-chat user ID.
  public let user: Int64
  /// The creation service-message ID, which may differ from the topic ID.
  public let message: Int32
  /// The topic ID used in reply and draft headers.
  public let topic: Int32
  /// Creates a topic record without validating its IDs.
  public init(user: Int64, message: Int32, topic: Int32) {
    self.user = user
    self.message = message
    self.topic = topic
  }
}

/// Topic requests only; callers own peers, pacing, persistence and retries.
/// Methods propagate transport errors and cancellation. Returned updates are not applied here.
public struct PrivateTopicClient: Sendable {
  private let api: TLClient

  /// Uses the supplied API transport; errors and cancellation propagate to the caller.
  public init(api: TLClient) { self.api = api }

  /// Opens a topic in the bot's private chat with `user`. Reusing
  /// `randomID` lets a retried request return the topic already created.
  /// The updates are returned for the caller to process normally.
  public func create(
    with user: TL.InputPeerType, userID: Int64, title: String, iconColor: Int32? = nil,
    randomID: Int64
  ) async throws -> (topicID: Int32, updates: TL.UpdatesType) {
    let title = ForumTopics.title(title)
    let updates = try await api.messages.createForumTopic(
      peer: user, title: title, iconColor: iconColor,
      randomId: randomID)
    guard let id = PrivateTopics.createdTopicID(in: updates, user: userID, randomID: randomID)
    else {
      throw PrivateTopicError.topicNotCreated
    }
    return (id, updates)
  }

  /// Renames a topic using a sanitized title and returns updates for the caller to process.
  public func rename(_ topic: Int32, with user: TL.InputPeerType, title: String) async throws
    -> TL.UpdatesType
  {
    try await api.messages.editForumTopic(
      peer: user, topicId: topic, title: ForumTopics.title(title))
  }

  /// Pins silently for both sides; in a topic it is that topic's pin.
  public func pin(_ message: Int32, with user: TL.InputPeerType) async throws -> TL.UpdatesType {
    try await api.messages.updatePinnedMessage(silent: true, peer: user, id: message)
  }

  /// Unpins the message silently for both sides and returns the resulting updates.
  public func unpin(_ message: Int32, with user: TL.InputPeerType) async throws -> TL.UpdatesType {
    try await api.messages.updatePinnedMessage(silent: true, unpin: true, peer: user, id: message)
  }

  /// The topic the service message `id` opened, when it is a topic creation.
  /// Repairs a topic recorded by its service message ID instead of its own.
  public func topicID(createdBy id: Int32, user: Int64) async throws -> Int32? {
    let result = try await api.messages.getMessages(id: [.inputMessageID(.init(id: id))])
    let messages: [TL.MessageType]
    switch result {
    case .messages(let value): messages = value.messages
    case .messagesSlice(let value): messages = value.messages
    case .channelMessages(let value): messages = value.messages
    case .messagesNotModified: messages = []
    }
    for case .messageService(let service) in messages where service.id == id {
      guard case .peerUser(let peer) = service.peerId, peer.userId == user,
        case .messageActionTopicCreate = service.action
      else { continue }
      return ForumTopics.createdTopicID(of: service)
    }
    return nil
  }

  /// The topics the bot opened among its private-chat message IDs `ids`,
  /// and the dates of every message found, so a scan knows where to stop.
  public func createdTopics(among ids: [Int32]) async throws -> (
    topics: [CreatedPrivateTopic], dates: [Int32]
  ) {
    guard !ids.isEmpty else { return ([], []) }
    let result = try await api.messages.getMessages(id: ids.map { .inputMessageID(.init(id: $0)) })
    let messages: [TL.MessageType]
    switch result {
    case .messages(let value): messages = value.messages
    case .messagesSlice(let value): messages = value.messages
    case .channelMessages(let value): messages = value.messages
    case .messagesNotModified: messages = []
    }
    var topics: [CreatedPrivateTopic] = []
    var dates: [Int32] = []
    for message in messages {
      switch message {
      case .message(let value): dates.append(value.date)
      case .messageService(let service):
        dates.append(service.date)
        guard service.out, case .peerUser(let peer) = service.peerId,
          case .messageActionTopicCreate = service.action
        else { continue }
        topics.append(
          .init(
            user: peer.userId, message: service.id, topic: ForumTopics.createdTopicID(of: service)))
      case .messageEmpty: continue
      }
    }
    return (topics, dates)
  }

  /// Deletes a topic and everything in it for both sides.
  public func delete(_ topic: Int32, with user: TL.InputPeerType) async throws {
    while try await api.messages.deleteTopicHistory(peer: user, topMsgId: topic).offset > 0 {}
  }

  /// The topics that still exist among `ids`; deleted ones come back as
  /// `forumTopicDeleted` and are left out.
  public func existing(_ ids: [Int32], with user: TL.InputPeerType) async throws -> Set<Int32> {
    guard !ids.isEmpty else { return [] }
    let result = try await api.messages.getForumTopicsByID(peer: user, topics: ids)
    return Set(
      result.topics.compactMap { topic in
        if case .forumTopic(let value) = topic { return value.id }
        return nil
      })
  }
}
