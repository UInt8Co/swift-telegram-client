import TelegramClient
import TelegramSchema
import Testing

private actor AdminPages {
  let pages: [TL.Channels.ChannelParticipantsType]
  var requests: [(filter: TL.ChannelParticipantsFilterType, offset: Int32, limit: Int32)] = []
  init(_ pages: [TL.Channels.ChannelParticipantsType]) { self.pages = pages }
  func list() async throws -> [ChatAdministrator] {
    try await ChatAdminLookup.channel { try await self.fetch(filter: $0, offset: $1, limit: $2) }
  }
  private func fetch(filter: TL.ChannelParticipantsFilterType, offset: Int32, limit: Int32) throws
    -> TL.Channels.ChannelParticipantsType
  {
    requests.append((filter, offset, limit))
    guard requests.count <= pages.count else { throw ParticipantLookupError.incompleteMembership }
    return pages[requests.count - 1]
  }
}

@Suite struct ChatAdminLookupTests {
  private func admin(_ id: Int64, delete: Bool = true, ban: Bool = true)
    -> TL.ChannelParticipantType
  {
    .channelParticipantAdmin(
      .init(
        userId: id, promotedBy: 1, date: 0,
        adminRights: .init(deleteMessages: delete, banUsers: ban)))
  }

  private func page(
    _ participants: [TL.ChannelParticipantType], count: Int32,
    users: [TL.UserType]
  ) -> TL.Channels.ChannelParticipantsType {
    .channelParticipants(.init(count: count, participants: participants, chats: [], users: users))
  }

  @Test func promotionRightsIncludeCreatorsAndBasicGroupAdmins() {
    let user = TL.User(id: 1)
    #expect(ChatAdministrator(user: user, isCreator: true, rights: .init()).canAddAdmins)
    #expect(ChatAdministrator(user: user, isCreator: false, rights: nil).canAddAdmins)
    #expect(
      ChatAdministrator(user: user, isCreator: false, rights: .init(addAdmins: true)).canAddAdmins)
    #expect(
      !ChatAdministrator(
        user: user, isCreator: false, rights: .init(deleteMessages: true, banUsers: true)
      ).canAddAdmins)
    #expect(!ChatAdministrator(user: user, isCreator: false, rights: .init()).canAddAdmins)
  }

  @Test func supergroupsPageThroughAllAdminsAndDecodeRights() async throws {
    let participants = (1...200).map { admin(Int64($0), delete: $0 != 1, ban: $0 != 2) }
    let users: [TL.UserType] = (1...200).map { id in
      .user(.init(deleted: id == 4, bot: id == 3, id: Int64(id)))
    }
    // A creator qualifies even if its rights flags are absent.
    let creator = TL.ChannelParticipantType.channelParticipantCreator(
      .init(userId: 201, adminRights: .init()))
    let lookup = AdminPages([
      page(participants, count: 201, users: users),
      page([creator], count: 201, users: [.user(.init(id: 201))]),
    ])
    #expect(try await lookup.list().map(\.user.id) == (1...201).map(Int64.init))
    let admins = try await AdminPages([
      page(
        [admin(1, delete: false), admin(2, ban: false), creator],
        count: 3, users: [.user(.init(id: 1)), .user(.init(id: 2)), .user(.init(id: 201))])
    ]).list()
    #expect(!admins[0].hasRights { $0.deleteMessages })
    #expect(!admins[1].hasRights { $0.banUsers })
    #expect(admins[2].isCreator && admins[2].hasRights { $0.deleteMessages && $0.banUsers })
    let requests = await lookup.requests
    #expect(requests.map(\.offset) == [0, 200])
    #expect(
      requests.allSatisfy { $0.limit == 200 && $0.filter == .channelParticipantsAdmins(.init()) })
  }

  @Test func shortPagesContinueAndUnknownUsersAreExcluded() async throws {
    let lookup = AdminPages([
      page([admin(1)], count: 3, users: [.userEmpty(.init(id: 1))]),
      page([admin(2), admin(3)], count: 3, users: [.user(.init(id: 3))]),
    ])
    #expect(try await lookup.list().map(\.user.id) == [3])
    #expect(await lookup.requests.map(\.offset) == [0, 1])
  }

  @Test func botsAndDeletedCreatorsArePreservedForCallerPolicy() async throws {
    let participants = [1, 2].map {
      TL.ChannelParticipantType.channelParticipantCreator(
        .init(userId: Int64($0), adminRights: .init()))
    }
    let lookup = AdminPages([
      page(
        participants, count: 2,
        users: [.user(.init(bot: true, id: 1)), .user(.init(deleted: true, id: 2))])
    ])
    #expect(try await lookup.list().map(\.user.id) == [1, 2])
  }

  @Test func incompletePagesThrowInsteadOfReturningAPartialRecipientList() async throws {
    let first = page([admin(1)], count: 2, users: [.user(.init(id: 1))])
    let broken: [[TL.Channels.ChannelParticipantsType]] = [
      [.channelParticipantsNotModified(.init())],
      [page([], count: -1, users: [])],
      [first, page([], count: 2, users: [])],
      [first, first],
      [first, page([admin(2)], count: 3, users: [.user(.init(id: 2))])],
      [page([admin(1)], count: 0, users: [.user(.init(id: 1))])],
    ]
    for pages in broken {
      await #expect(throws: ParticipantLookupError.self) { try await AdminPages(pages).list() }
    }
    await #expect(throws: CancellationError.self) {
      try await ChatAdminLookup.channel { _, _, _ in throw CancellationError() }
    }
  }

  @Test func basicGroupsUseFullChatCreatorsAndAdmins() throws {
    let participants: [TL.ChatParticipantType] = [
      .chatParticipantCreator(.init(userId: 1)),
      .chatParticipantAdmin(.init(userId: 2, inviterId: 1, date: 0)),
      .chatParticipantAdmin(.init(userId: 3, inviterId: 1, date: 0)),
      .chatParticipantAdmin(.init(userId: 4, inviterId: 1, date: 0)),
      .chatParticipant(.init(userId: 5, inviterId: 1, date: 0)),
      .chatParticipantAdmin(.init(userId: 6, inviterId: 1, date: 0)),
    ]
    let result = TL.Messages.ChatFull(
      fullChat: .chatFull(
        .init(
          id: 100, about: "",
          participants: .chatParticipants(
            .init(chatId: 100, participants: participants, version: 1)), notifySettings: .init())),
      chats: [],
      users: [
        .user(.init(id: 1)), .user(.init(id: 2)), .user(.init(bot: true, id: 3)),
        .user(.init(deleted: true, id: 4)), .user(.init(id: 5)), .userEmpty(.init(id: 6)),
      ])
    let admins = try ChatAdminLookup.basic(result)
    #expect(admins.map(\.user.id) == [1, 2, 3, 4])
    #expect(admins[0].isCreator && !admins[1].isCreator)
    #expect(admins.allSatisfy { $0.hasRights { $0.deleteMessages && $0.banUsers } })
  }

  @Test func basicGroupsWithHiddenParticipantsRemainRetryable() {
    let result = TL.Messages.ChatFull(
      fullChat: .chatFull(
        .init(
          id: 100, about: "",
          participants: .chatParticipantsForbidden(.init(chatId: 100)), notifySettings: .init())),
      chats: [], users: [])
    #expect(throws: ParticipantLookupError.self) { try ChatAdminLookup.basic(result) }
  }

  @Test func rightsChangesInvalidateTheGroupEvenWhenTheUserRemainsAnAdmin() {
    let change = TL.UpdateType.updateChannelParticipant(
      .init(
        channelId: 100, date: 1, actorId: 1, userId: 7,
        prevParticipant: admin(7), newParticipant: admin(7, ban: false), qts: 1))
    #expect(ChatAdminLookup.changedGroup(in: change) == .peerChannel(.init(channelId: 100)))
    #expect(
      ChatAdminLookup.changedGroup(
        in: .updateChatParticipantAdmin(.init(chatId: 200, userId: 7, isAdmin: false, version: 1)))
        == .peerChat(.init(chatId: 200)))
    #expect(
      ChatAdminLookup.changedGroup(
        in: .updateChatParticipants(
          .init(participants: .chatParticipantsForbidden(.init(chatId: 200)))))
        == .peerChat(.init(chatId: 200)))
  }
}

extension ChatAdminLookupTests {
  @Test func ordinaryJoinsLeavesAndBansDoNotInvalidateAdmins() {
    let member = TL.ChannelParticipantType.channelParticipant(.init(userId: 7, date: 0))
    for (before, after) in [(nil, member), (member, nil), (member, member)] {
      let change = TL.UpdateType.updateChannelParticipant(
        .init(
          channelId: 100, date: 1, actorId: 1, userId: 7,
          prevParticipant: before, newParticipant: after, qts: 1))
      #expect(ChatAdminLookup.changedGroup(in: change) == nil)
    }
    #expect(ChatAdminLookup.changedGroup(in: .updateChannel(.init(channelId: 100))) == nil)
    #expect(ChatAdminLookup.changedGroup(in: .updateChat(.init(chatId: 100))) == nil)
    #expect(
      ChatAdminLookup.changedGroup(
        in: .updateChatParticipantAdd(
          .init(chatId: 100, userId: 7, inviterId: 1, date: 0, version: 1))) == nil)
    let deletion = TL.UpdateType.updateChatParticipantDelete(
      .init(chatId: 100, userId: 7, version: 1))
    #expect(ChatAdminLookup.changedGroup(in: deletion, previousBasicAdmins: [1: true]) == nil)
    #expect(
      ChatAdminLookup.changedGroup(in: deletion, previousBasicAdmins: [1: true, 7: false]) != nil)
    let demotion = TL.UpdateType.updateChannelParticipant(
      .init(
        channelId: 100, date: 1, actorId: 1, userId: 7,
        prevParticipant: admin(7), newParticipant: member, qts: 1))
    #expect(ChatAdminLookup.changedGroup(in: demotion) != nil)
  }

  @Test func fullBasicParticipantListsCompareAdminRolesOnly() {
    let original: [TL.ChatParticipantType] = [
      .chatParticipantCreator(.init(userId: 1)),
      .chatParticipantAdmin(.init(userId: 2, inviterId: 1, date: 0)),
    ]
    let roles = ChatAdminLookup.basicAdminRoles(original)
    let joined = original + [.chatParticipant(.init(userId: 3, inviterId: 1, date: 0))]
    let update = TL.UpdateType.updateChatParticipants(
      .init(participants: .chatParticipants(.init(chatId: 100, participants: joined, version: 1))))
    #expect(ChatAdminLookup.changedGroup(in: update, previousBasicAdmins: roles) == nil)
    #expect(ChatAdminLookup.changedGroup(in: update, previousBasicAdmins: [1: true]) != nil)
    #expect(
      ChatAdminLookup.changedGroup(in: update, previousBasicAdmins: [1: false, 2: false]) != nil)
  }
}
