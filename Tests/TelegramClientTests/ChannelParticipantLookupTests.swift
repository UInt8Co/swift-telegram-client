import MTProtoClientKit
import TelegramClient
import TelegramSchema
import Testing

actor ParticipantLookupFixture {
  var requests: [(filter: TL.ChannelParticipantsFilterType, offset: Int32, limit: Int32)] = []
  private let participant: TL.ChannelParticipantType?
  private let lookupFailure: (any Error)?
  private let pages: [TL.Channels.ChannelParticipantsType]
  private let pageFailure: (any Error)?
  private let expectedCount: Int32

  init(
    participant: TL.ChannelParticipantType? = nil,
    lookupFailure: (any Error)? = TelegramClientError.userNotFound(7),
    pages: [TL.Channels.ChannelParticipantsType] = [], pageFailure: (any Error)? = nil,
    expectedCount: Int32? = nil
  ) {
    self.participant = participant
    self.lookupFailure = lookupFailure
    self.pages = pages
    self.pageFailure = pageFailure
    if let expectedCount {
      self.expectedCount = expectedCount
    } else if case .channelParticipants(let page)? = pages.first {
      self.expectedCount = page.count
    } else {
      self.expectedCount = 0
    }
  }

  func contains(_ userID: Int64 = 7, role: ChannelParticipantLookup.Role) async throws -> Bool {
    try await ChannelParticipantLookup.contains(
      userID: userID, role: role,
      participant: { try await self.lookup() },
      count: { self.expectedCount },
      page: { try await self.fetch(filter: $0, offset: $1, limit: $2) })
  }

  private func lookup() throws -> TL.ChannelParticipantType? {
    if let lookupFailure { throw lookupFailure }
    return participant
  }

  private func fetch(filter: TL.ChannelParticipantsFilterType, offset: Int32, limit: Int32) throws
    -> TL.Channels.ChannelParticipantsType
  {
    requests.append((filter, offset, limit))
    if let pageFailure { throw pageFailure }
    guard requests.count <= pages.count else { throw ParticipantLookupError.incompleteMembership }
    return pages[requests.count - 1]
  }

  static func page(_ participants: [TL.ChannelParticipantType], count: Int32? = nil)
    -> TL.Channels.ChannelParticipantsType
  {
    .channelParticipants(
      .init(
        count: count ?? Int32(participants.count), participants: participants, chats: [], users: [])
    )
  }
}

@Suite struct ChannelParticipantLookupTests {
  private let member = TL.ChannelParticipantType.channelParticipant(.init(userId: 7, date: 0))
  private let admin = TL.ChannelParticipantType.channelParticipantAdmin(
    .init(userId: 7, promotedBy: 1, date: 0, adminRights: .init()))

  @Test func successfulIndividualLookupsDoNotFetchLists() async throws {
    for participant in [nil, member, admin] {
      for role in [ChannelParticipantLookup.Role.member, .admin] {
        let lookup = ParticipantLookupFixture(participant: participant, lookupFailure: nil)
        #expect(try await lookup.contains(role: role) == (participant.flatMap(role.userID) == 7))
        #expect(await lookup.requests.isEmpty)
      }
    }
  }

  @Test(arguments: [false, true])
  func visibilityFailuresUseTheAppropriateList(rpc: Bool) async throws {
    let error: any Error =
      rpc
      ? MTProtoRPCError(code: 400, message: "USER_ID_INVALID") : TelegramClientError.userNotFound(7)
    for role in [ChannelParticipantLookup.Role.member, .admin] {
      let lookup = ParticipantLookupFixture(
        lookupFailure: error,
        pages: [
          .channelParticipants(
            .init(
              count: 1, participants: [admin], chats: [], users: []))
        ])
      // Numeric participant IDs suffice even when Telegram omits users.
      #expect(try await lookup.contains(role: role))
      let requests = await lookup.requests
      #expect(requests.count == 1)
      #expect(requests.first?.filter == role.filter)
      #expect(requests.first?.offset == 0 && requests.first?.limit == 200)
    }
  }

  /// Telegram answers getParticipant for a deleted account with
  /// PARTICIPANT_ID_INVALID; only the list can decide.
  @Test func unresolvableParticipantsUseTheCompleteList() async throws {
    let error = MTProtoRPCError(code: 400, message: "PARTICIPANT_ID_INVALID")
    let other = TL.ChannelParticipantType.channelParticipant(.init(userId: 1, date: 0))
    let absent = ParticipantLookupFixture(
      lookupFailure: error, pages: [ParticipantLookupFixture.page([other])])
    #expect(try await !absent.contains(role: .member))
    #expect(await absent.requests.count == 1)
    let present = ParticipantLookupFixture(
      lookupFailure: error, pages: [ParticipantLookupFixture.page([other, member])])
    #expect(try await present.contains(role: .member))
  }

  @Test func restrictedMembersAndCreatorsRemainMembers() async throws {
    let restricted = TL.ChannelParticipantType.channelParticipantBanned(
      .init(
        peer: .peerUser(.init(userId: 7)),
        kickedBy: 1, date: 0, bannedRights: .init(sendMessages: true, untilDate: 0)))
    let creator = TL.ChannelParticipantType.channelParticipantCreator(
      .init(userId: 7, adminRights: .init()))
    #expect(
      try await ParticipantLookupFixture(pages: [ParticipantLookupFixture.page([restricted])])
        .contains(role: .member))
    #expect(
      try await ParticipantLookupFixture(pages: [ParticipantLookupFixture.page([creator])])
        .contains(role: .admin))
  }

  @Test(arguments: [false, true])
  func absenceRequiresAllPagesAndLaterPagesCanFindTheUser(present: Bool) async throws {
    let first = (100...299).map {
      TL.ChannelParticipantType.channelParticipant(.init(userId: Int64($0), date: 0))
    }
    let last = present ? member : .channelParticipant(.init(userId: 300, date: 0))
    let lookup = ParticipantLookupFixture(pages: [
      ParticipantLookupFixture.page(first, count: 201),
      ParticipantLookupFixture.page([last], count: 201),
    ])
    #expect(try await lookup.contains(role: .member) == present)
    #expect(await lookup.requests.map(\.offset) == [0, 200])
  }

  @Test func shortPagesAreNotMistakenForTheEndOfTheList() async throws {
    let other = TL.ChannelParticipantType.channelParticipant(.init(userId: 1, date: 0))
    let lookup = ParticipantLookupFixture(pages: [
      ParticipantLookupFixture.page([other], count: 2),
      ParticipantLookupFixture.page([member], count: 2),
    ])
    #expect(try await lookup.contains(role: .member))
    #expect(await lookup.requests.map(\.offset) == [0, 1])
  }

  @Test func incompleteListsNeverProveAbsence() async throws {
    let other = TL.ChannelParticipantType.channelParticipant(.init(userId: 1, date: 0))
    let broken: [[TL.Channels.ChannelParticipantsType]] = [
      [.channelParticipantsNotModified(.init())],
      [ParticipantLookupFixture.page([], count: 1)],
      [ParticipantLookupFixture.page([], count: -1)],
      [ParticipantLookupFixture.page([other], count: 0)],
      [
        ParticipantLookupFixture.page([other], count: 2),
        ParticipantLookupFixture.page([], count: 2),
      ],
      [ParticipantLookupFixture.page([other], count: 2), .channelParticipantsNotModified(.init())],
      [
        ParticipantLookupFixture.page([other], count: 2),
        ParticipantLookupFixture.page([other], count: 2),
      ],
      [
        ParticipantLookupFixture.page([other], count: 2),
        ParticipantLookupFixture.page([], count: 1),
      ],
      [
        ParticipantLookupFixture.page([
          .channelParticipantLeft(.init(peer: .peerUser(.init(userId: 1))))
        ])
      ],
    ]
    for pages in broken {
      let lookup = ParticipantLookupFixture(pages: pages)
      do {
        _ = try await lookup.contains(role: .member)
        Issue.record("An incomplete list produced a membership answer")
      } catch {
        guard case .incompleteMembership = error as? ParticipantLookupError else { throw error }
      }
    }
    // An ordinary member returned by an admin-only query is not a complete admin list.
    await #expect(throws: ParticipantLookupError.self) {
      try await ParticipantLookupFixture(pages: [ParticipantLookupFixture.page([other])]).contains(
        role: .admin)
    }
    // A self-consistent page can still be only the visible subset.
    await #expect(throws: ParticipantLookupError.self) {
      try await ParticipantLookupFixture(
        pages: [ParticipantLookupFixture.page([other])], expectedCount: 2
      ).contains(role: .member)
    }
  }

  @Test func hiddenOrUncountedMembershipCannotProveAbsence() throws {
    var channel = TL.ChannelFull(
      canViewParticipants: true, id: 100, about: "", participantsCount: 3, adminsCount: 1,
      readInboxMaxId: 0, readOutboxMaxId: 0, unreadCount: 0, chatPhoto: .photoEmpty(.init(id: 0)),
      notifySettings: .init(), botInfo: [], pts: 0)
    #expect(try ChannelParticipantLookup.Role.member.count(in: .channelFull(channel)) == 3)
    #expect(try ChannelParticipantLookup.Role.admin.count(in: .channelFull(channel)) == 1)
    channel.canViewParticipants = false
    #expect(throws: ParticipantLookupError.self) {
      try ChannelParticipantLookup.Role.member.count(in: .channelFull(channel))
    }
    // Admin-only listings do not require access to the full member list.
    #expect(try ChannelParticipantLookup.Role.admin.count(in: .channelFull(channel)) == 1)
    channel.canViewParticipants = true
    channel.participantsCount = nil
    channel.adminsCount = nil
    for role in [ChannelParticipantLookup.Role.member, .admin] {
      #expect(throws: ParticipantLookupError.self) { try role.count(in: .channelFull(channel)) }
    }
  }

  @Test func unrelatedLookupErrorsDoNotUseTheFallback() async throws {
    let errors: [any Error] = [
      CancellationError(), MTProtoClientError.timeout,
      MTProtoRPCError(code: 420, message: "FLOOD_WAIT_60"),
      MTProtoRPCError(code: 403, message: "CHAT_ADMIN_REQUIRED"),
      TelegramClientError.peerNotFound("channel:100"),
    ]
    for error in errors {
      let lookup = ParticipantLookupFixture(
        lookupFailure: error, pages: [ParticipantLookupFixture.page([])])
      do {
        _ = try await lookup.contains(role: .member)
        Issue.record("A failed lookup produced a membership answer")
      } catch let received { #expect(String(describing: received) == String(describing: error)) }
      #expect(await lookup.requests.isEmpty)
    }
  }

  @Test func listingErrorsKeepTheirOriginalRetryAndFloodWaitHandling() async throws {
    let errors: [any Error] = [
      CancellationError(), MTProtoClientError.timeout,
      MTProtoRPCError(code: 420, message: "FLOOD_WAIT_60"),
      MTProtoRPCError(code: 403, message: "CHAT_ADMIN_REQUIRED"),
    ]
    for error in errors {
      let lookup = ParticipantLookupFixture(pageFailure: error)
      do {
        _ = try await lookup.contains(role: .admin)
        Issue.record("A failed listing produced a membership answer")
      } catch let received { #expect(String(describing: received) == String(describing: error)) }
      #expect(await lookup.requests.count == 1)
    }
  }
  @Test func groupMembershipDistinguishesRestrictedMembersFromAbsentUsers() {
    let user: Int64 = 7
    let peer = TL.PeerType.peerUser(.init(userId: user))
    let members: [TL.ChannelParticipantType] = [
      .channelParticipant(.init(userId: user, date: 0)),
      .channelParticipantSelf(.init(userId: user, inviterId: 1, date: 0)),
      .channelParticipantAdmin(.init(userId: user, promotedBy: 1, date: 0, adminRights: .init())),
      .channelParticipantCreator(.init(userId: user, adminRights: .init())),
      .channelParticipantBanned(
        .init(
          peer: peer, kickedBy: 1, date: 0,
          bannedRights: .init(sendMessages: true, untilDate: 0))),
    ]
    for participant in members { #expect(ChannelParticipantLookup.memberID(participant) == user) }
    let absent: [TL.ChannelParticipantType] = [
      .channelParticipantLeft(.init(peer: peer)),
      .channelParticipantBanned(
        .init(
          left: true, peer: peer, kickedBy: 1, date: 0,
          bannedRights: .init(sendMessages: true, untilDate: 0))),
      .channelParticipantBanned(
        .init(
          peer: peer, kickedBy: 1, date: 0,
          bannedRights: .init(viewMessages: true, untilDate: 0))),
    ]
    for participant in absent { #expect(ChannelParticipantLookup.memberID(participant) == nil) }
  }
}
