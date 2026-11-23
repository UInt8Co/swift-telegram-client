import Testing
import TelegramSchema
@testable import TelegramClient

@Suite struct ChatMemberListingTests {
  private func page(_ participants: [TL.ChannelParticipantType], count: Int32,
    users: [TL.UserType] = []) -> TL.Channels.ChannelParticipantsType {
    .channelParticipants(.init(count: count, participants: participants, chats: [], users: users))
  }

  @Test func rolesAndDeletedProofSurviveProjection() throws {
    let result = try ChatMemberListing.channel(page([
      .channelParticipantCreator(.init(userId: 1, adminRights: .init())),
      .channelParticipantAdmin(.init(userId: 2, promotedBy: 1, date: 0, adminRights: .init())),
      .channelParticipant(.init(userId: 3, date: 0)),
      .channelParticipant(.init(userId: 4, date: 0)),
    ], count: 6, users: [.user(.init(deleted: true, id: 3)), .userEmpty(.init(id: 4))]), offset: 0)
    #expect(result.members.map(\.role) == [.creator, .administrator, .member, .member])
    #expect(result.members.map(\.isDeleted) == [false, false, true, false])
    #expect(result.nextOffset == 4)
  }

  @Test func membershipDatesAndBotsSurviveProjection() throws {
    let result = try ChatMemberListing.channel(page([
      .channelParticipantCreator(.init(userId: 1, adminRights: .init())),
      .channelParticipantAdmin(.init(userId: 2, promotedBy: 1, date: 200, adminRights: .init())),
      .channelParticipant(.init(userId: 3, date: 300)),
      .channelParticipantSelf(.init(userId: 4, inviterId: 1, date: 400)),
      .channelParticipantBanned(.init(peer: .peerUser(.init(userId: 5)), kickedBy: 1, date: 500,
        bannedRights: .init(sendMessages: true, untilDate: 0))),
      .channelParticipant(.init(userId: 6, date: 0)),
    ], count: 6, users: [.user(.init(bot: true, id: 4)), .user(.init(id: 3)), .userEmpty(.init(id: 6))]), offset: 0)
    #expect(result.members.map(\.memberSince) == [nil, 200, 300, 400, 500, nil])
    #expect(result.members.map(\.isBot) == [false, false, false, true, false, false])

    let full = TL.Messages.ChatFull(fullChat: .chatFull(.init(id: 10, about: "",
      participants: .chatParticipants(.init(chatId: 10, participants: [
        .chatParticipantCreator(.init(userId: 1)),
        .chatParticipantAdmin(.init(userId: 2, inviterId: 1, date: 20)),
        .chatParticipant(.init(userId: 3, inviterId: 1, date: 30)),
      ], version: 1)), notifySettings: .init())), chats: [], users: [.user(.init(bot: true, id: 3))])
    let basic = try ChatMemberListing.basic(full, offset: 0)
    #expect(basic.members.map(\.memberSince) == [nil, 20, 30])
    #expect(basic.members.map(\.isBot) == [false, false, true])
  }

  @Test func cursorCountsExcludedParticipantsAndKeepsRestrictedMembers() throws {
    let result = try ChatMemberListing.channel(page([
      .channelParticipantLeft(.init(peer: .peerUser(.init(userId: 1)))),
      .channelParticipantBanned(.init(peer: .peerUser(.init(userId: 2)), kickedBy: 1, date: 0,
        bannedRights: .init(sendMessages: true, untilDate: 0))),
      .channelParticipantBanned(.init(left: true, peer: .peerUser(.init(userId: 3)), kickedBy: 1,
        date: 0, bannedRights: .init(viewMessages: true, untilDate: 0))),
    ], count: 10), offset: 4)
    #expect(result.members.map(\.userID) == [2])
    #expect(result.nextOffset == 7)
  }

  @Test func incompleteAndInvalidPagesThrow() {
    let invalid: [(TL.Channels.ChannelParticipantsType, Int32)] = [
      (.channelParticipantsNotModified(.init()), 0),
      (page([], count: 0), -1), (page([], count: -1), 0),
      (page([.channelParticipant(.init(userId: 1, date: 0)),
        .channelParticipant(.init(userId: 1, date: 0))], count: 2), 0),
      (page([.channelParticipant(.init(userId: 1, date: 0))], count: .max), .max),
    ]
    for (response, offset) in invalid {
      #expect(throws: ParticipantLookupError.self) { try ChatMemberListing.channel(response, offset: offset) }
    }
    #expect(throws: ParticipantLookupError.self) { try ChatMemberListing.channel(page([], count: 0), offset: 0, limit: 0) }
  }

  @Test func permanentlyPartialListsFinishVisibleEnumeration() throws {
    let first = try ChatMemberListing.channel(page([.channelParticipant(.init(userId: 7, date: 0))], count: 1000), offset: 0)
    #expect(first.members.map(\.userID) == [7])
    #expect(first.nextOffset == 1)
    let last = try ChatMemberListing.channel(page([], count: 1000), offset: 1)
    #expect(last.members.isEmpty)
    #expect(last.nextOffset == nil)
  }

  @Test func basicGroupsPageByRawListAndRequireVisibleParticipants() throws {
    let full = TL.Messages.ChatFull(fullChat: .chatFull(.init(id: 10, about: "",
      participants: .chatParticipants(.init(chatId: 10, participants: [
        .chatParticipantCreator(.init(userId: 1)),
        .chatParticipantAdmin(.init(userId: 2, inviterId: 1, date: 0)),
        .chatParticipant(.init(userId: 3, inviterId: 1, date: 0)),
      ], version: 1)), notifySettings: .init())), chats: [], users: [.user(.init(deleted: true, id: 3))])
    let first = try ChatMemberListing.basic(full, offset: 0, limit: 2)
    #expect(first.members.map(\.role) == [.creator, .administrator])
    #expect(first.nextOffset == 2)
    let last = try ChatMemberListing.basic(full, offset: 2, limit: 2)
    #expect(last.members == [.init(userID: 3, isDeleted: true)])
    #expect(last.nextOffset == nil)
    let hidden = TL.Messages.ChatFull(fullChat: .chatFull(.init(id: 10, about: "",
      participants: .chatParticipantsForbidden(.init(chatId: 10)), notifySettings: .init())), chats: [], users: [])
    #expect(throws: ParticipantLookupError.self) { try ChatMemberListing.basic(hidden, offset: 0) }
  }
}
