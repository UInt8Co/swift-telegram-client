import TelegramSchema
import Testing
import TelegramBot
import TelegramClient

@Suite struct BotGroupAdditionEventTests {
  let bot: Int64 = 99
  var member: TL.ChannelParticipantType { .channelParticipant(.init(userId: bot, date: 10)) }

  func channel(actor: Int64 = 7, previous: TL.ChannelParticipantType? = nil,
        next: TL.ChannelParticipantType? = nil) -> TL.UpdateType {
    .updateChannelParticipant(.init(channelId: 100, date: 10, actorId: actor, userId: bot,
      prevParticipant: previous, newParticipant: next ?? member, qts: 42))
  }

  @Test func channelAdditionFromAbsentLeftAndKickedButNotPromotionOrUnrestriction() throws {
    let left = TL.ChannelParticipantType.channelParticipantLeft(.init(peer: .peerUser(.init(userId: bot))))
    let kicked = TL.ChannelParticipantType.channelParticipantBanned(.init(left: true, peer: .peerUser(.init(userId: bot)),
      kickedBy: 7, date: 9, bannedRights: .init(viewMessages: true, untilDate: 0)))
    let restricted = TL.ChannelParticipantType.channelParticipantBanned(.init(peer: .peerUser(.init(userId: bot)),
      kickedBy: 7, date: 9, bannedRights: .init(sendMessages: true, untilDate: 0)))
    for previous in [nil, left, kicked] {
      let addition = try #require(BotGroupAdditionEvent.parse(channel(previous: previous), botID: bot))
      #expect(addition.group == .init(kind: .channel, id: 100))
      #expect(addition.by.id == 7 && addition.date == 10 && addition.sourceID == 42)
    }
    #expect(BotGroupAdditionEvent.parse(channel(previous: member), botID: bot) == nil)
    #expect(BotGroupAdditionEvent.parse(channel(previous: restricted), botID: bot) == nil)
    #expect(BotGroupAdditionEvent.parse(channel(next: kicked), botID: bot) == nil)
    #expect(BotGroupAdditionEvent.parse(channel(next: left), botID: bot) == nil)
    #expect(BotGroupAdditionEvent.parse(.updateChannelParticipant(.init(channelId: 100, date: 10,
      actorId: 7, userId: bot, prevParticipant: member, qts: 42)), botID: bot) == nil)
  }

  @Test func inviterAndDirectAdminPromoterFallbacks() throws {
    let invited = TL.ChannelParticipantType.channelParticipantSelf(.init(userId: bot, inviterId: 8, date: 10))
    let admin = TL.ChannelParticipantType.channelParticipantAdmin(.init(userId: bot, promotedBy: 9, date: 10, adminRights: .init()))
    let invitedAdmin = TL.ChannelParticipantType.channelParticipantAdmin(.init(self_: true, userId: bot,
      inviterId: 8, promotedBy: 9, date: 10, adminRights: .init()))
    #expect(BotGroupAdditionEvent.parse(channel(actor: 0, next: invited), botID: bot)?.by.id == 8)
    #expect(BotGroupAdditionEvent.parse(channel(actor: 0, next: admin), botID: bot)?.by.id == 9)
    #expect(BotGroupAdditionEvent.parse(channel(actor: 0, next: invitedAdmin), botID: bot)?.by.id == 8)
    #expect(BotGroupAdditionEvent.parse(channel(actor: 7, next: admin), botID: bot)?.by.id == 7)
    #expect(BotGroupAdditionEvent.parse(channel(actor: bot, next: invited), botID: bot) == nil)
    #expect(BotGroupAdditionEvent.parse(channel(actor: 0), botID: bot) == nil)
    #expect(BotGroupAdditionEvent.parse(channel(previous: member, next: admin), botID: bot) == nil)
  }

  @Test func basicParticipantForms() throws {
    let add = TL.UpdateType.updateChatParticipantAdd(.init(chatId: 100, userId: bot, inviterId: 7, date: 10, version: 6))
    #expect(BotGroupAdditionEvent.parse(add, botID: bot)?.by.id == 7)
    #expect(BotGroupAdditionEvent.parse(add, botID: bot)?.group == .init(kind: .chat, id: 100))
    #expect(BotGroupAdditionEvent.parse(add, botID: 123) == nil)
    let member = TL.ChatParticipantType.chatParticipant(.init(userId: bot, inviterId: 7, date: 10))
    let participant = TL.UpdateType.updateChatParticipant(.init(chatId: 100, date: 10, actorId: 7,
      userId: bot, newParticipant: member, qts: 42))
    #expect(BotGroupAdditionEvent.parse(participant, botID: bot)?.by.id == 7)
    let promotion = TL.UpdateType.updateChatParticipant(.init(chatId: 100, date: 10, actorId: 7,
      userId: bot, prevParticipant: member, newParticipant: .chatParticipantAdmin(.init(userId: bot, inviterId: 7, date: 10)), qts: 43))
    #expect(BotGroupAdditionEvent.parse(promotion, botID: bot) == nil)
    #expect(BotGroupAdditionEvent.parse(.updateChatParticipantAdd(.init(chatId: 100, userId: bot, inviterId: bot, date: 10, version: 6)), botID: bot) == nil)
  }

  @Test func basicServiceMessageAndCatchupMessage() throws {
    let service = TL.MessageType.messageService(.init(id: 11, fromId: .peerUser(.init(userId: 7)),
      peerId: .peerChat(.init(chatId: 100)), date: 10, action: .messageActionChatAddUser(.init(users: [bot, 9]))))
    let update = TL.UpdateType.updateNewMessage(.init(message: service, pts: 1, ptsCount: 1))
    let addition = try #require(BotGroupAdditionEvent.parse(update, botID: bot))
    #expect(addition.source == .serviceMessage && addition.sourceID == 11 && addition.by.id == 7)
    #expect(BotGroupAdditionEvent.parse(service, botID: bot) == addition)
    #expect(BotGroupAdditionEvent.parse(update, botID: 12) == nil)
    #expect(BotGroupAdditionEvent.parse(.updateEditMessage(.init(message: service, pts: 2, ptsCount: 1)), botID: bot) == nil)
    for from in [nil, TL.PeerType.peerUser(.init(userId: bot)), .peerChannel(.init(channelId: 7))] {
      let unknown = TL.MessageType.messageService(.init(id: 12, fromId: from,
        peerId: .peerChat(.init(chatId: 100)), date: 10, action: .messageActionChatAddUser(.init(users: [bot]))))
      #expect(BotGroupAdditionEvent.parse(unknown, botID: bot) == nil)
    }
  }
}
