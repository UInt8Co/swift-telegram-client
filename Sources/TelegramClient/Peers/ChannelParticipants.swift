import MTProtoClientKit
import TelegramSchema

/// Individual participant lookup with a complete-list fallback.
public enum ChannelParticipantLookup {
  /// The participant role to query and validate.
  public enum Role: Sendable, Hashable {
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
      guard case .channelFull(let channel) = info else {
        throw ParticipantLookupError.incomplete(.unavailableCount)
      }
      let count: Int32?
      switch self {
      case .member:
        // A recent-members query can expose only a subset when the
        // member list is hidden. Its own count cannot prove absence.
        guard channel.canViewParticipants else { throw ParticipantLookupError.incomplete(.hiddenParticipants) }
        count = channel.participantsCount
      case .admin: count = channel.adminsCount
      }
      guard let count, count >= 0 else { throw ParticipantLookupError.incomplete(.unavailableCount) }
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
  public static func contains(
    userID: Int64, role: Role,
    participant: @Sendable () async throws -> TL.ChannelParticipantType?,
    count: @Sendable () async throws -> Int32,
    page:
      @Sendable (TL.ChannelParticipantsFilterType, Int32, Int32) async throws ->
      TL.Channels.ChannelParticipantsType
  ) async throws -> Bool {
    try await contains(userID: userID, role: role, participant: participant) {
      try await fallback(userID: userID, role: role, count: count, page: page)
    }
  }

  /// Supplies a shared fallback policy while keeping individual lookups fresh.
  public static func contains(
    userID: Int64, role: Role,
    participant: @Sendable () async throws -> TL.ChannelParticipantType?,
    fallback: @Sendable () async throws -> Bool
  ) async throws -> Bool {
    do {
      guard let participant = try await participant() else { return false }
      return role.userID(participant) == userID
    } catch where PeerAccessFailure.userUnavailable(error) || isUnresolvableParticipant(error) {
      try Task.checkCancellation()
    }
    return try await fallback()
  }

  /// A returned matching participant proves presence even in a partial list.
  /// Absence requires a visible, complete traversal of the list's own count,
  /// and that count must cover a fresh authoritative count supplied by the
  /// caller. Telegram's full-info count routinely trails the list by a few
  /// members, so a larger list count still proves absence; a smaller one may
  /// be a subset and never does. No count, transport or cancellation error
  /// is converted to absence. The count is fetched only when a page misses.
  public static func fallback(
    userID: Int64, role: Role,
    count: @Sendable () async throws -> Int32,
    page: @Sendable (TL.ChannelParticipantsFilterType, Int32, Int32) async throws -> TL.Channels.ChannelParticipantsType,
    completed: @Sendable (Set<Int64>) async -> Void = { _ in }
  ) async throws -> Bool {
    var expectedCount: Int32?
    var countRead = false
    var incomplete: ParticipantLookupError?
    var seen: Set<Int64> = []
    // Telegram may never expose every member. Bound work even if it keeps
    // returning distinct pages without reaching the advertised count.
    for _ in 0..<5 {
      try Task.checkCancellation()
      let offset = Int32(seen.count)
      let response = try await page(role.filter, offset, 200)
      try Task.checkCancellation()
      guard case .channelParticipants(let result) = response else {
        throw ParticipantLookupError.incomplete(.notModified(offset: offset))
      }
      // Check positive evidence before completeness: a count mismatch, duplicate
      // or unrelated entry cannot erase the target's explicit participant record.
      if result.participants.contains(where: { role.userID($0) == userID }) { return true }
      if !countRead {
        countRead = true
        do { expectedCount = try await count() }
        catch let error as ParticipantLookupError { incomplete = error }
      }
      try Task.checkCancellation()
      if let expectedCount, expectedCount >= 0 {
        if result.count < expectedCount, incomplete == nil {
          incomplete = .incomplete(.countMismatch(expected: expectedCount, actual: result.count, offset: offset))
        }
      } else if incomplete == nil { incomplete = .incomplete(.unavailableCount) }
      // Keep looking for positive evidence in accessible later pages, even
      // when visibility/counts already rule out proving absence.
      guard result.count >= 0 else { throw incomplete ?? .incomplete(.unavailableCount) }
      for participant in result.participants {
        guard let id = role.userID(participant) else {
          throw ParticipantLookupError.incomplete(.unexpectedParticipant(offset: offset))
        }
        guard seen.insert(id).inserted else {
          throw ParticipantLookupError.incomplete(.duplicateParticipant(userID: id, offset: offset))
        }
      }
      guard seen.count <= Int(result.count) else {
        throw ParticipantLookupError.incomplete(.tooManyParticipants(expected: result.count, seen: seen.count))
      }
      if seen.count == Int(result.count) {
        if let incomplete { throw incomplete }
        await completed(seen)
        return false
      }
      guard !result.participants.isEmpty else {
        throw incomplete ?? .incomplete(.earlyEnd(expected: result.count, seen: seen.count))
      }
    }
    throw incomplete ?? .incomplete(.traversalLimit(seen: seen.count))
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
