import TelegramClient
import TelegramSchema
import Testing

@Suite struct GroupServiceEventsTests {
  @Test func membershipUpdatesIdentifyBothGroupKinds() {
    let updates: [TL.UpdateType] = [
      .updateChatParticipant(.init(chatId: 50, date: 1, actorId: 11, userId: 12, qts: 1)),
      .updateChatParticipantAdd(.init(chatId: 50, userId: 12, inviterId: 11, date: 1, version: 1)),
      .updateChatParticipantDelete(.init(chatId: 50, userId: 12, version: 2)),
      .updateChatParticipantAdmin(.init(chatId: 50, userId: 12, isAdmin: true, version: 3)),
      .updateChatParticipants(.init(participants: .chatParticipants(.init(chatId: 50, participants: [], version: 4)))),
      .updateChatParticipants(.init(participants: .chatParticipantsForbidden(.init(chatId: 50))))
    ]
    for update in updates { #expect(GroupServiceEvents.membershipGroup(update) == .init(kind: .chat, id: 50)) }
    #expect(GroupServiceEvents.membershipGroup(.updateChannelParticipant(.init(channelId: 50,
      date: 1, actorId: 11, userId: 12, qts: 1))) == .init(kind: .channel, id: 50))
  }

  @Test func serviceActionsHaveDistinctJoinAndRefreshContracts() {
    let actions: [(TL.MessageActionType, Bool, Bool)] = [
      (.messageActionChatAddUser(.init(users: [12])), true, true),
      (.messageActionChatDeleteUser(.init(userId: 12)), false, true),
      (.messageActionChatJoinedByLink(.init(inviterId: 11)), true, true),
      (.messageActionChatJoinedByRequest(.init()), true, true),
      (.messageActionChatJoinedViaCommunity(.init(communityId: 60)), true, false),
      (.messageActionChatEditTitle(.init(title: "New title")), false, false)
    ]
    for (action, join, refresh) in actions {
      for peer in [PeerID(kind: .chat, id: 50), .init(kind: .channel, id: 50)] {
        let message = TL.MessageType.messageService(.init(id: 1, peerId: peer.tl, date: 1, action: action))
        #expect(GroupServiceEvents.isJoin(message) == join)
        #expect(GroupServiceEvents.membershipGroup(message) == (refresh ? peer : nil))
        for update in [TL.UpdateType.updateNewMessage(.init(message: message, pts: 1, ptsCount: 1)),
          .updateNewChannelMessage(.init(message: message, pts: 1, ptsCount: 1))] {
          #expect(GroupServiceEvents.membershipGroup(update) == (refresh ? peer : nil))
        }
      }
      let privateMessage = TL.MessageType.messageService(.init(id: 1,
        peerId: .peerUser(.init(userId: 7)), date: 1, action: action))
      #expect(!GroupServiceEvents.isJoin(privateMessage))
    }
    let message = TL.MessageType.message(.init(id: 1, peerId: .peerChat(.init(chatId: 50)), date: 1, message: "Hi"))
    #expect(!GroupServiceEvents.isJoin(message))
    #expect(GroupServiceEvents.membershipGroup(message) == nil)
  }
}
