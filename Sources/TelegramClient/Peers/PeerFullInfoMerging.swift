import TelegramSchema

extension TelegramPeerInfoMerging {
  /// Applies supported full-user fields, preserving every other field. Returns nil for
  /// unsupported updates. The caller must match the update to this peer and account.
  public static func fullUser(_ response: TL.Users.UserFull, applying update: TL.UpdateType) -> TL.Users.UserFull? {
    var response = response
    switch update {
    case .updatePeerBlocked(let value):
      response.fullUser.blocked = value.blocked
      response.fullUser.blockedMyStoriesFrom = value.blockedMyStoriesFrom
    case .updatePeerSettings(let value): response.fullUser.settings = value.settings
    case .updatePeerWallpaper(let value):
      response.fullUser.wallpaper = value.wallpaper
      response.fullUser.wallpaperOverridden = value.wallpaperOverridden
    default: return nil
    }
    return response
  }

  /// Applies supported full-channel fields. Returns nil for non-channel responses or
  /// unsupported updates. The caller must match the update to this peer and account.
  public static func fullChannel(_ response: TL.Messages.ChatFull, applying update: TL.UpdateType) -> TL.Messages.ChatFull? {
    var response = response
    guard case .channelFull(var channel) = response.fullChat else { return nil }
    switch update {
    case .updatePeerBlocked(let value): channel.blocked = value.blocked
    case .updatePeerWallpaper(let value): channel.wallpaper = value.wallpaper
    case .updateChannelAvailableMessages(let value):
      channel.availableMinId = value.availableMinId
      channel.hiddenPrehistory = true
    default: return nil
    }
    response.fullChat = .channelFull(channel)
    return response
  }

  /// A versioned basic-group transformation; storage invalidation belongs to the caller.
  public enum BasicGroupUpdate: Sendable {
    /// The incoming version is no newer than the cached version.
    case unchanged
    /// A version gap requires invalidating both the basic and full cached records.
    case invalidated
    /// A contiguous update with its transformed basic-group value.
    case updated(TL.Chat)
  }

  /// Advances a basic group only by a single version. Explicit count is applied before
  /// delta; the delta result is clamped to a nonnegative Int32. Caller supplies the peer,
  /// version and count facts from the update; account-specific rights invalidation is separate.
  public static func basicGroup(_ chat: TL.Chat, applying update: TL.UpdateType,
    version: Int32, count: Int32? = nil, delta: Int32? = nil) -> BasicGroupUpdate {
    guard version > chat.version else { return .unchanged }
    guard Int64(version) == Int64(chat.version) + 1 else { return .invalidated }
    var chat = chat
    chat.version = version
    if let count { chat.participantsCount = count }
    if let delta { chat.participantsCount = Int32(clamping: max(0, Int64(chat.participantsCount) + Int64(delta))) }
    if case .updateChatDefaultBannedRights(let value) = update { chat.defaultBannedRights = value.defaultBannedRights }
    return .updated(chat)
  }

  /// Transforms a cached basic group's participant list. Nil means invalidate: the cached
  /// list is absent, its version differs from `previousVersion`, or an edited member is
  /// missing. Caller must establish a contiguous basic-group update first. A full list
  /// replacement retains its own version; other updates advance to the supplied version.
  /// Unsupported updates only advance the version, preserving the participant list.
  public static func basicGroupParticipants(_ response: TL.Messages.ChatFull, applying update: TL.UpdateType,
    previousVersion: Int32, version: Int32) -> TL.Messages.ChatFull? {
    var response = response
    guard case .chatFull(var full) = response.fullChat,
      case .chatParticipants(var participants) = full.participants, participants.version == previousVersion else {
      return nil
    }
    switch update {
    case .updateChatParticipants(let value): full.participants = value.participants
    case .updateChatParticipantAdd(let value):
      participants.participants.removeAll { participantID($0) == value.userId }
      participants.participants.append(.chatParticipant(.init(userId: value.userId, inviterId: value.inviterId, date: value.date)))
    case .updateChatParticipantDelete(let value):
      participants.participants.removeAll { participantID($0) == value.userId }
    case .updateChatParticipantAdmin(let value):
      guard let index = participants.participants.firstIndex(where: { participantID($0) == value.userId }) else {
        return nil
      }
      switch participants.participants[index] {
      case .chatParticipant(let user) where value.isAdmin:
        participants.participants[index] = .chatParticipantAdmin(.init(userId: user.userId, inviterId: user.inviterId, date: user.date, rank: user.rank))
      case .chatParticipantAdmin(let user) where !value.isAdmin:
        participants.participants[index] = .chatParticipant(.init(userId: user.userId, inviterId: user.inviterId, date: user.date, rank: user.rank))
      default: break
      }
    case .updateChatParticipantRank(let value):
      guard let index = participants.participants.firstIndex(where: { participantID($0) == value.userId }) else {
        return nil
      }
      switch participants.participants[index] {
      case .chatParticipant(var user): user.rank = value.rank; participants.participants[index] = .chatParticipant(user)
      case .chatParticipantAdmin(var user): user.rank = value.rank; participants.participants[index] = .chatParticipantAdmin(user)
      case .chatParticipantCreator(var user): user.rank = value.rank; participants.participants[index] = .chatParticipantCreator(user)
      }
    default: break
    }
    if case .updateChatParticipants = update {} else {
      participants.version = version
      full.participants = .chatParticipants(participants)
    }
    response.fullChat = .chatFull(full)
    return response
  }

  /// The user ID in any basic-group participant entry, including creators and administrators.
  public static func participantID(_ participant: TL.ChatParticipantType) -> Int64 {
    switch participant {
    case .chatParticipant(let value): value.userId
    case .chatParticipantCreator(let value): value.userId
    case .chatParticipantAdmin(let value): value.userId
    }
  }

}
