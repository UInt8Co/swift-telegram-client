import TelegramSchema

/// A current member's identity and role, without application moderation policy.
public struct ChatMember: Sendable, Equatable {
  public enum Role: Sendable, Equatable { case member, administrator, creator }
  public var userID: Int64
  public var role: Role
  /// Only an explicit `user.deleted` flag proves deletion; a missing user does not.
  public var isDeleted: Bool

  public init(userID: Int64, role: Role = .member, isDeleted: Bool = false) {
    self.userID = userID
    self.role = role
    self.isDeleted = isDeleted
  }
}

/// One page, whose cursor counts raw participants (including excluded entries).
public struct ChatMemberPage: Sendable, Equatable {
  public var members: [ChatMember]
  public var nextOffset: Int32?

  public init(members: [ChatMember], nextOffset: Int32?) {
    self.members = members
    self.nextOffset = nextOffset
  }
}

/// Stateless projections for restartable member enumeration. Callers own RPCs,
/// persistence, retries and scheduling. Channel RPCs must use hash zero and the
/// recent-participants filter. Lists are live: insertions/removals can change offsets.
public enum ChatMemberListing {
  public static func channel(_ response: TL.Channels.ChannelParticipantsType,
    offset: Int32, limit: Int32 = 200) throws -> ChatMemberPage {
    guard offset >= 0, limit > 0, case .channelParticipants(let page) = response,
      page.count >= 0, page.participants.count <= Int(limit)
    else { throw ParticipantLookupError.incompleteMembership }
    let end = Int64(offset) + Int64(page.participants.count)
    guard end <= Int64(Int32.max), !page.participants.isEmpty || offset >= page.count else {
      throw ParticipantLookupError.incompleteMembership
    }
    let deleted = deletedIDs(page.users)
    var seen: Set<Int64> = []
    let members = try page.participants.compactMap { participant -> ChatMember? in
      guard let id = ChannelParticipantLookup.memberID(participant) else { return nil }
      guard seen.insert(id).inserted else { throw ParticipantLookupError.incompleteMembership }
      let role: ChatMember.Role
      switch participant {
      case .channelParticipantCreator: role = .creator
      case .channelParticipantAdmin: role = .administrator
      default: role = .member
      }
      return .init(userID: id, role: role, isDeleted: deleted.contains(id))
    }
    return .init(members: members, nextOffset: end < Int64(page.count) ? Int32(end) : nil)
  }

  public static func basic(_ response: TL.Messages.ChatFull,
    offset: Int32, limit: Int32 = 200) throws -> ChatMemberPage {
    guard offset >= 0, limit > 0, case .chatFull(let full) = response.fullChat,
      case .chatParticipants(let list) = full.participants
    else { throw ParticipantLookupError.incompleteMembership }
    let deleted = deletedIDs(response.users)
    let end = min(Int64(offset) + Int64(limit), Int64(list.participants.count))
    var seen: Set<Int64> = []
    let members = try list.participants.dropFirst(Int(offset)).prefix(Int(limit)).map { participant in
      let id: Int64
      let role: ChatMember.Role
      switch participant {
      case .chatParticipant(let value): id = value.userId; role = .member
      case .chatParticipantAdmin(let value): id = value.userId; role = .administrator
      case .chatParticipantCreator(let value): id = value.userId; role = .creator
      }
      guard seen.insert(id).inserted else { throw ParticipantLookupError.incompleteMembership }
      return ChatMember(userID: id, role: role, isDeleted: deleted.contains(id))
    }
    return .init(members: members, nextOffset: end < list.participants.count ? Int32(end) : nil)
  }

  private static func deletedIDs(_ users: [TL.UserType]) -> Set<Int64> {
    Set(users.compactMap { if case .user(let user) = $0, user.deleted { user.id } else { nil } })
  }
}
