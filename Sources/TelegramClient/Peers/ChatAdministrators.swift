import TelegramSchema

/// An administrator response could not establish a complete participant traversal.
public enum ParticipantLookupError: Error, Equatable {
  /// Participants are hidden, repeated, missing, inconsistent or unavailable.
  case incompleteMembership
}

/// Compatibility name for the shared participant completeness error.
public typealias ChatAdminLookupError = ParticipantLookupError

/// The user and rights from an administrator entry, without application policy.
public struct ChatAdministrator: Sendable, Equatable {
  /// The resolved user; bots and deleted users are retained.
  public var user: TL.User
  /// Whether the participant owns the chat.
  public var isCreator: Bool
  /// Basic-group administrators have all rights; their TL entry has no flags.
  public var rights: TL.ChatAdminRights?

  /// Creates an administrator projection with the original rights flags.
  public init(user: TL.User, isCreator: Bool, rights: TL.ChatAdminRights?) {
    self.user = user
    self.isCreator = isCreator
    self.rights = rights
  }

  /// Creators and basic-group admins can promote others without explicit flags.
  public var canAddAdmins: Bool { hasRights { $0.addAdmins } }

  /// Tests rights, treating creators and basic-group administrators as having all rights.
  public func hasRights(_ predicate: (TL.ChatAdminRights) -> Bool) -> Bool {
    isCreator || (rights.map(predicate) ?? true)
  }
}

/// Stateless administrator enumeration and cache-invalidation hints.
public enum ChatAdminLookup {
  /// Pages all admins, retaining bots and deleted users for callers to filter.
  /// Participant order is retained. Missing user objects are omitted even when
  /// pagination completes. Inconsistent pages throw; transport errors propagate.
  /// Cancellation is checked before each page; the supplied closure owns RPC cancellation.
  public static func channel(
    page:
      @Sendable (TL.ChannelParticipantsFilterType, Int32, Int32) async throws ->
      TL.Channels.ChannelParticipantsType
  ) async throws -> [ChatAdministrator] {
    var seen: Set<Int64> = []
    var admins: [ChatAdministrator] = []
    var expectedCount: Int32?
    while true {
      try Task.checkCancellation()
      let response = try await page(.channelParticipantsAdmins(.init()), Int32(seen.count), 200)
      guard case .channelParticipants(let result) = response,
        result.count >= 0, expectedCount == nil || result.count == expectedCount
      else {
        throw ChatAdminLookupError.incompleteMembership
      }
      expectedCount = result.count
      let users = usersByID(result.users)
      for participant in result.participants {
        let id: Int64
        let creator: Bool
        let rights: TL.ChatAdminRights
        switch participant {
        case .channelParticipantCreator(let value):
          id = value.userId
          creator = true
          rights = value.adminRights
        case .channelParticipantAdmin(let value):
          id = value.userId
          creator = false
          rights = value.adminRights
        default: throw ChatAdminLookupError.incompleteMembership
        }
        guard seen.insert(id).inserted else { throw ChatAdminLookupError.incompleteMembership }
        if let user = users[id] {
          admins.append(.init(user: user, isCreator: creator, rights: rights))
        }
      }
      guard seen.count <= Int(result.count) else { throw ChatAdminLookupError.incompleteMembership }
      if seen.count == Int(result.count) { return admins }
      guard !result.participants.isEmpty else { throw ChatAdminLookupError.incompleteMembership }
    }
  }

  /// Projects basic-group creators and administrators in participant order.
  /// Missing user objects are omitted and duplicate IDs are collapsed.
  /// Throws if the full participant list is unavailable.
  public static func basic(_ result: TL.Messages.ChatFull) throws -> [ChatAdministrator] {
    guard case .chatFull(let full) = result.fullChat,
      case .chatParticipants(let list) = full.participants
    else {
      throw ChatAdminLookupError.incompleteMembership
    }
    let users = usersByID(result.users)
    var seen: Set<Int64> = []
    return list.participants.compactMap { participant in
      let id: Int64
      let creator: Bool
      switch participant {
      case .chatParticipantCreator(let value):
        id = value.userId
        creator = true
      case .chatParticipantAdmin(let value):
        id = value.userId
        creator = false
      case .chatParticipant: return nil
      }
      guard let user = users[id], seen.insert(id).inserted else { return nil }
      return .init(user: user, isCreator: creator, rights: nil)
    }
  }

  private static func usersByID(_ users: [TL.UserType]) -> [Int64: TL.User] {
    var result: [Int64: TL.User] = [:]
    for case .user(let user) in users { result[user.id] = user }
    return result
  }

  /// Only administrator membership/rights changes invalidate this cache.
  /// Full basic-group lists compare roles, ignoring ordinary joins/leaves.
  /// Unknown first snapshots are refreshed once to establish a baseline.
  public static func changedGroup(
    in update: TL.UpdateType, previousBasicAdmins: [Int64: Bool]? = nil
  ) -> TL.PeerType? {
    switch update {
    case .updateChannelParticipant(let value):
      guard isAdmin(value.prevParticipant) || isAdmin(value.newParticipant) else { return nil }
      return .peerChannel(.init(channelId: value.channelId))
    case .updateChatParticipant(let value):
      guard isAdmin(value.prevParticipant) || isAdmin(value.newParticipant) else { return nil }
      return .peerChat(.init(chatId: value.chatId))
    case .updateChatParticipantDelete(let value):
      guard previousBasicAdmins?[value.userId] != nil else { return nil }
      return .peerChat(.init(chatId: value.chatId))
    case .updateChatParticipantAdmin(let value): return .peerChat(.init(chatId: value.chatId))
    case .updateChatParticipants(let value):
      switch value.participants {
      case .chatParticipants(let list):
        guard previousBasicAdmins != basicAdminRoles(list.participants) else { return nil }
        return .peerChat(.init(chatId: list.chatId))
      case .chatParticipantsForbidden(let list):
        return .peerChat(.init(chatId: list.chatId))
      }
    default: return nil
    }
  }

  /// true means creator, false means administrator; absence means member.
  public static func basicAdminRoles(_ participants: [TL.ChatParticipantType]) -> [Int64: Bool] {
    var result: [Int64: Bool] = [:]
    for participant in participants {
      switch participant {
      case .chatParticipantCreator(let value): result[value.userId] = true
      case .chatParticipantAdmin(let value): result[value.userId] = false
      default: break
      }
    }
    return result
  }

  private static func isAdmin(_ participant: TL.ChannelParticipantType?) -> Bool {
    switch participant {
    case .channelParticipantAdmin?, .channelParticipantCreator?: true
    default: false
    }
  }
  private static func isAdmin(_ participant: TL.ChatParticipantType?) -> Bool {
    switch participant {
    case .chatParticipantAdmin?, .chatParticipantCreator?: true
    default: false
    }
  }
}
