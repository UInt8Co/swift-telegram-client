import TelegramSchema
import TelegramClient
import Testing

@Suite struct PeerFullInfoMergingTests {
  let peer = TL.PeerType.peerUser(.init(userId: 42))

  @Test func fullUserChangesOnlySupportedFields() throws {
    let original = TL.Users.UserFull(fullUser: .init(id: 42, about: "About", settings: .init(),
      notifySettings: .init(), commonChatsCount: 0), chats: [], users: [])
    let blocked = try #require(TelegramPeerInfoMerging.fullUser(original,
      applying: .updatePeerBlocked(.init(blocked: true, blockedMyStoriesFrom: true, peerId: peer))))
    #expect(blocked.fullUser.blocked && blocked.fullUser.blockedMyStoriesFrom)
    #expect(blocked.fullUser.about == original.fullUser.about)
    let settings = try #require(TelegramPeerInfoMerging.fullUser(blocked,
      applying: .updatePeerSettings(.init(peer: peer, settings: .init(reportSpam: true)))))
    #expect(settings.fullUser.settings.reportSpam && settings.fullUser.blocked)
    #expect(TelegramPeerInfoMerging.fullUser(original, applying: .updateUser(.init(userId: 42))) == nil)
    #expect(!original.fullUser.blocked)
  }

  @Test func channelUpdatesPreserveUnrelatedFields() throws {
    let original = TL.Messages.ChatFull(fullChat: .channelFull(.init(id: 42, about: "About",
      readInboxMaxId: 3, readOutboxMaxId: 2, unreadCount: 1, chatPhoto: .photoEmpty(.init(id: 0)),
      notifySettings: .init(), botInfo: [], pts: 10)), chats: [], users: [])
    let updated = try #require(TelegramPeerInfoMerging.fullChannel(original,
      applying: .updateChannelAvailableMessages(.init(channelId: 42, availableMinId: 8))))
    guard case .channelFull(let full) = updated.fullChat else { Issue.record("Expected channel"); return }
    #expect(full.availableMinId == 8 && full.hiddenPrehistory && full.pts == 10 && full.about == "About")
    #expect(TelegramPeerInfoMerging.fullChannel(original, applying: .updateUser(.init(userId: 42))) == nil)
  }

  @Test func basicVersionsRequireContiguityAndClampCounts() {
    let chat = TL.Chat(id: 42, title: "Group", photo: .chatPhotoEmpty(.init()), participantsCount: 2, date: 1, version: 5)
    let update = TL.UpdateType.updateChatParticipantDelete(.init(chatId: 42, userId: 9, version: 6))
    guard case .unchanged = TelegramPeerInfoMerging.basicGroup(chat, applying: update, version: 5),
      case .invalidated = TelegramPeerInfoMerging.basicGroup(chat, applying: update, version: 7),
      case .updated(let next) = TelegramPeerInfoMerging.basicGroup(chat, applying: update, version: 6, count: 1, delta: -5)
    else { Issue.record("Unexpected version decision"); return }
    #expect(next.version == 6 && next.participantsCount == 0 && next.title == chat.title)
    guard case .updated(let maximum) = TelegramPeerInfoMerging.basicGroup(chat, applying: update, version: 6, count: .max, delta: .max)
    else { Issue.record("Expected update"); return }
    #expect(maximum.participantsCount == .max)
  }

  private func response(_ participants: [TL.ChatParticipantType], version: Int32 = 5) -> TL.Messages.ChatFull {
    .init(fullChat: .chatFull(.init(id: 42, about: "About", participants: .chatParticipants(.init(
      chatId: 42, participants: participants, version: version)), notifySettings: .init())), chats: [], users: [])
  }

  @Test func participantTransformsPreserveRanksAndInvalidateMissingEdits() throws {
    let member = TL.ChatParticipantType.chatParticipant(.init(userId: 9, inviterId: 3, date: 2, rank: "Member"))
    let original = response([member])
    let promote = TL.UpdateType.updateChatParticipantAdmin(.init(chatId: 42, userId: 9, isAdmin: true, version: 6))
    let promoted = try #require(TelegramPeerInfoMerging.basicGroupParticipants(original, applying: promote, previousVersion: 5, version: 6))
    guard case .chatFull(let full) = promoted.fullChat, case .chatParticipants(let list) = full.participants,
      case .chatParticipantAdmin(let admin) = list.participants.first else { Issue.record("Expected administrator"); return }
    #expect(admin.rank == "Member" && admin.inviterId == 3 && admin.date == 2 && list.version == 6)
    #expect(TelegramPeerInfoMerging.basicGroupParticipants(original, applying: promote, previousVersion: 4, version: 5) == nil)
    #expect(TelegramPeerInfoMerging.basicGroupParticipants(response([]), applying: promote, previousVersion: 5, version: 6) == nil)
    let rank = TL.UpdateType.updateChatParticipantRank(.init(chatId: 42, userId: 9, rank: "Editor", version: 7))
    let ranked = try #require(TelegramPeerInfoMerging.basicGroupParticipants(promoted, applying: rank, previousVersion: 6, version: 7))
    guard case .chatFull(let rankedFull) = ranked.fullChat, case .chatParticipants(let rankedList) = rankedFull.participants,
      case .chatParticipantAdmin(let rankedAdmin) = rankedList.participants.first else { Issue.record("Expected administrator"); return }
    #expect(rankedAdmin.rank == "Editor")
    let replacement = TL.ChatParticipantsType.chatParticipants(.init(chatId: 42, participants: [], version: 10))
    let replaced = try #require(TelegramPeerInfoMerging.basicGroupParticipants(original,
      applying: .updateChatParticipants(.init(participants: replacement)), previousVersion: 5, version: 6))
    guard case .chatFull(let replacedFull) = replaced.fullChat else { Issue.record("Expected group"); return }
    #expect(replacedFull.participants == replacement)
  }
}
