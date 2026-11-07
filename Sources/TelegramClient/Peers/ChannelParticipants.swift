import MTProtoClientKit
import TelegramSchema

/// Individual participant lookup with a complete-list fallback.
public enum ChannelParticipantLookup {
  /// The participant role to query and validate.
  public enum Role: Sendable {
    /// Any current member, including a restricted user who can view messages.
    case member
    /// Only administrators and creators.
    case admin

    /// The Telegram filter for this role.
    public var filter: TL.ChannelParticipantsFilterType {
      switch self {
      case .member: .channelParticipantsRecent(.init())
      case .admin: .channelParticipantsAdmins(.init())
      }
    }

    /// Projects a user matching this role, excluding left or removed users.
    public func userID(_ participant: TL.ChannelParticipantType) -> Int64? {
      switch self {
      case .member: ChannelParticipantLookup.memberID(participant)
      case .admin:
        switch participant {
        case .channelParticipantAdmin(let value): value.userId
        case .channelParticipantCreator(let value): value.userId
        default: nil
        }
      }
    }

    /// Requires a nonnegative authoritative count and visible member lists.
    public func count(in info: TL.ChatFullType) throws -> Int32 {
      guard case .channelFull(let channel) = info else { throw ParticipantLookupError.incompleteMembership }
      let count: Int32?
      switch self {
      case .member:
        // A recent-members query can expose only a subset when the
        // member list is hidden. Its own count cannot prove absence.
        guard channel.canViewParticipants else { throw ParticipantLookupError.incompleteMembership }
        count = channel.participantsCount
      case .admin: count = channel.adminsCount
      }
      guard let count, count >= 0 else { throw ParticipantLookupError.incompleteMembership }
      return count
    }
  }

  /// `channels.getParticipant` answers PARTICIPANT_ID_INVALID for a target it
  /// cannot resolve, such as a deleted account. That says nothing about
  /// membership, so the complete list decides instead.
  public static func isUnresolvableParticipant(_ error: any Error) -> Bool {
    (error as? MTProtoRPCError)?.message == "PARTICIPANT_ID_INVALID"
  }

  /// Tries an individual lookup, then traverses a complete list for unresolvable users.
  /// Nil from the individual lookup means absence. Partial lists never prove absence;
  /// they throw `ParticipantLookupError`. Transport errors propagate unchanged.
  /// Cancellation is checked during fallback; supplied closures own RPC cancellation.
  public static func contains(userID: Int64, role: Role,
            participant: @Sendable () async throws -> TL.ChannelParticipantType?,
            count: @Sendable () async throws -> Int32,
            page: @Sendable (TL.ChannelParticipantsFilterType, Int32, Int32) async throws -> TL.Channels.ChannelParticipantsType) async throws -> Bool {
    do {
      guard let participant = try await participant() else { return false }
      return role.userID(participant) == userID
    } catch where PeerAccessFailure.userUnavailable(error) || isUnresolvableParticipant(error) {
      try Task.checkCancellation()
    }

    // hash = 0 at the call site requests a full response. NotModified,
    // early exhaustion, duplicate entries and changing counts all leave
    // membership unknown.
    // https://core.telegram.org/constructor/channels.channelParticipants
    let expectedCount = try await count()
    guard expectedCount >= 0 else { throw ParticipantLookupError.incompleteMembership }
    var seen: Set<Int64> = []
    while true {
      try Task.checkCancellation()
      let response = try await page(role.filter, Int32(seen.count), 200)
      try Task.checkCancellation()
      guard case .channelParticipants(let result) = response, result.count == expectedCount else {
        throw ParticipantLookupError.incompleteMembership
      }
      for participant in result.participants {
        guard let id = role.userID(participant), seen.insert(id).inserted else {
          throw ParticipantLookupError.incompleteMembership
        }
        if id == userID { return true }
      }
      guard seen.count <= Int(result.count) else { throw ParticipantLookupError.incompleteMembership }
      if seen.count == Int(result.count) { return false }
      guard !result.participants.isEmpty else { throw ParticipantLookupError.incompleteMembership }
    }
  }

  /// Current user members, including restricted users who have not left and can view messages.
  public static func memberID(_ participant: TL.ChannelParticipantType) -> Int64? {
    switch participant {
    case .channelParticipant(let value): value.userId
    case .channelParticipantSelf(let value): value.userId
    case .channelParticipantAdmin(let value): value.userId
    case .channelParticipantCreator(let value): value.userId
    case .channelParticipantBanned(let value):
      !value.left && !value.bannedRights.viewMessages ? userID(value.peer) : nil
    case .channelParticipantLeft: nil
    }
  }

  private static func userID(_ peer: TL.PeerType) -> Int64? {
    if case .peerUser(let value) = peer { return value.userId }
    return nil
  }
}
