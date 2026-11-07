import TelegramSchema

/// Extracts only Telegram's private-chat draft Stop action.
public enum DraftStop {
  /// Other typing actions and group typing updates are not stop requests.
  public static func parse(_ update: TL.UpdateType) -> (
    userID: Int64, topicID: Int32?, draftID: Int64
  )? {
    guard case .updateUserTyping(let value) = update,
      case .sendMessageStopDraftAction(let action) = value.action
    else { return nil }
    return (value.userId, value.topMsgId, action.randomId)
  }
}

/// Sends ephemeral rich-message drafts; callers own rendering, pacing and logs.
public struct DraftClient: Sendable {
  private let api: TLClient

  /// Uses the same API transport as the caller's ordinary messages.
  public init(api: TLClient) { self.api = api }

  /// Shows or refreshes a draft. Reuse a non-zero ID while its content grows.
  @discardableResult
  public func show(
    peer: TL.InputPeerType, topicID: Int32? = nil, richMessage: TL.InputRichMessageType,
    draftID: Int64, canStop: Bool = true, keepOnStop: Bool = true
  ) async throws -> Bool {
    guard draftID != 0 else { throw DraftClientError.zeroDraftID }
    return try await api.messages.setTyping(
      peer: peer, topMsgId: topicID,
      action: .inputSendMessageRichMessageDraftAction(
        .init(
          canStop: canStop, keepOnStop: keepOnStop,
          randomId: draftID, richMessage: richMessage)))
  }
}

/// Invalid draft requests rejected before reaching Telegram.
public enum DraftClientError: Error, Sendable, Equatable {
  /// Telegram draft IDs must be nonzero.
  case zeroDraftID
}
