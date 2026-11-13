import TLCoding
import TelegramClient
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct RPCRequestSummaryTests {
  struct Case: CustomTestStringConvertible, Sendable {
    var function: any TLFunction
    var name: String
    var peer: String?
    var testDescription: String { "\(name) → \(peer ?? "nil")" }

    init(_ function: any TLFunction, _ name: String, _ peer: String?) {
      self.function = function
      self.name = name
      self.peer = peer
    }
  }

  private static let hash: Int64 = 999_999
  private static let user = TL.InputPeerType.inputPeerUser(.init(userId: 7, accessHash: hash))
  private static let channel = TL.InputPeerType.inputPeerChannel(.init(channelId: 42, accessHash: hash))
  private static let inputUser = TL.InputUserType.inputUser(.init(userId: 7, accessHash: hash))
  private static let inputChannel = TL.InputChannelType.inputChannel(
    .init(channelId: 42, accessHash: hash))
  private static let fromMessage = TL.InputPeerType.inputPeerUserFromMessage(
    .init(peer: channel, msgId: 1, userId: 7))
  private static let empty = TL.InputMediaType.inputMediaEmpty(.init())
  private static let cancel = TL.SendMessageActionType.sendMessageCancelAction(.init())
  private static let filter = TL.ChannelMessagesFilterType.channelMessagesFilterEmpty(.init())

  /// The strings `describe` gave for these requests when it parsed their bytes,
  /// which consumers key flood holds and logs by.
  static let cases: [Case] = [
    Case(
      TL.Messages.SendMessage(peer: channel, message: "PRIVATE MESSAGE", randomId: 123),
      "messages.sendMessage", "channel:42"),
    Case(
      TL.Messages.SendMessage(peer: .inputPeerChat(.init(chatId: 5)), message: "x", randomId: 1),
      "messages.sendMessage", "chat:5"),
    Case(
      TL.Messages.SendMessage(peer: .inputPeerSelf(.init()), message: "x", randomId: 1),
      "messages.sendMessage", "self"),
    Case(
      TL.Messages.SendMessage(peer: .inputPeerEmpty(.init()), message: "x", randomId: 1),
      "messages.sendMessage", nil),
    Case(
      TL.Messages.SendMessage(peer: fromMessage, message: "x", randomId: 1),
      "messages.sendMessage", nil),
    Case(
      TL.Messages.SendMedia(peer: user, media: empty, message: "x", randomId: 1),
      "messages.sendMedia", "user:7"),
    Case(
      TL.Messages.EditMessage(peer: channel, id: 1, message: "PRIVATE"),
      "messages.editMessage", "channel:42"),
    // The source, which leads; the destination comes later.
    Case(
      TL.Messages.ForwardMessages(fromPeer: user, id: [1], randomId: [2], toPeer: channel),
      "messages.forwardMessages", "user:7"),
    Case(TL.Messages.GetChats(id: [10, 20]), "messages.getChats", "chat:10 (+1 peers)"),
    Case(TL.Messages.GetChats(id: [10]), "messages.getChats", "chat:10"),
    Case(TL.Messages.GetChats(id: []), "messages.getChats", nil),
    Case(TL.Messages.GetFullChat(chatId: 34), "messages.getFullChat", "chat:34"),
    Case(
      TL.Messages.DeleteChatUser(revokeHistory: true, chatId: 33, userId: inputUser),
      "messages.deleteChatUser", "chat:33"),
    Case(
      TL.Messages.UploadMedia(businessConnectionId: "short", peer: user, media: empty),
      "messages.uploadMedia", "user:7"),
    Case(
      TL.Messages.UploadMedia(
        businessConnectionId: String(repeating: "x", count: 300), peer: user, media: empty),
      "messages.uploadMedia", "user:7"),
    Case(TL.Messages.UploadMedia(peer: channel, media: empty), "messages.uploadMedia", "channel:42"),
    Case(TL.Messages.SetTyping(peer: user, action: cancel), "messages.setTyping", "user:7"),
    Case(
      TL.Messages.UpdatePinnedMessage(unpin: true, peer: channel, id: 3),
      "messages.updatePinnedMessage", "channel:42"),
    Case(
      TL.Messages.HideChatJoinRequest(approved: true, peer: channel, userId: inputUser),
      "messages.hideChatJoinRequest", "channel:42"),
    Case(
      TL.Messages.CreateForumTopic(peer: channel, title: "t", randomId: 1),
      "messages.createForumTopic", "channel:42"),
    Case(
      TL.Messages.EditForumTopic(peer: channel, topicId: 1, title: "t"),
      "messages.editForumTopic", "channel:42"),
    Case(
      TL.Messages.DeleteTopicHistory(peer: channel, topMsgId: 1),
      "messages.deleteTopicHistory", "channel:42"),
    Case(
      TL.Messages.GetForumTopicsByID(peer: channel, topics: [1]),
      "messages.getForumTopicsByID", "channel:42"),
    Case(TL.Users.GetUsers(id: [inputUser]), "users.getUsers", "user:7"),
    Case(
      TL.Users.GetUsers(id: [.inputUserSelf(.init()), inputUser, inputUser]),
      "users.getUsers", "self (+2 peers)"),
    Case(
      TL.Users.GetUsers(id: [.inputUserFromMessage(.init(peer: channel, msgId: 1, userId: 7)), inputUser]),
      "users.getUsers", nil),
    Case(TL.Users.GetUsers(id: []), "users.getUsers", nil),
    Case(TL.Users.GetFullUser(id: .inputUserSelf(.init())), "users.getFullUser", "self"),
    Case(TL.Users.GetFullUser(id: .inputUserEmpty(.init())), "users.getFullUser", nil),
    Case(
      TL.Channels.GetChannels(id: [inputChannel, .inputChannelEmpty(.init())]),
      "channels.getChannels", "channel:42 (+1 peers)"),
    Case(TL.Channels.GetFullChannel(channel: inputChannel), "channels.getFullChannel", "channel:42"),
    Case(
      TL.Channels.GetFullChannel(
        channel: .inputChannelFromMessage(.init(peer: user, msgId: 1, channelId: 42))),
      "channels.getFullChannel", nil),
    Case(
      TL.Channels.EditBanned(
        channel: inputChannel, participant: user, bannedRights: TL.ChatBannedRights(untilDate: 0)),
      "channels.editBanned", "channel:42"),
    Case(
      TL.Channels.DeleteMessages(channel: inputChannel, id: [1]), "channels.deleteMessages",
      "channel:42"),
    Case(
      TL.Channels.GetParticipant(channel: inputChannel, participant: user),
      "channels.getParticipant", "channel:42"),
    Case(
      TL.Updates.GetChannelDifference(
        force: true, channel: inputChannel, filter: filter, pts: 1, limit: 10),
      "updates.getChannelDifference", "channel:42"),
    // An ephemeral message names its peer when it has one, else its receiver.
    Case(
      TL.Ephemeral.SendMessage(
        peer: channel, receiverId: inputUser, message: "PRIVATE", randomId: 1),
      "ephemeral.sendMessage", "channel:42"),
    Case(
      TL.Ephemeral.SendMessage(receiverId: inputUser, message: "PRIVATE", randomId: 1),
      "ephemeral.sendMessage", "user:7"),
    Case(
      TL.Ephemeral.DeleteMessage(receiverId: .inputUserSelf(.init()), id: 1),
      "ephemeral.deleteMessage", "self"),
    Case(
      TL.Payments.RefundStarsCharge(userId: inputUser, chargeId: "c"), "payments.refundStarsCharge",
      "user:7"),
    Case(
      TL.Payments.BotCancelStarsSubscription(restore: true, userId: inputUser, chargeId: "c"),
      "payments.botCancelStarsSubscription", "user:7"),
    Case(
      TL.Payments.GetSavedStarGifts(peer: channel, offset: "", limit: 1),
      "payments.getSavedStarGifts", "channel:42"),
    // Known methods without a leading peer.
    Case(TL.Help.GetConfig(), "help.getConfig", nil),
    Case(TL.Messages.GetMessages(id: [.inputMessageID(.init(id: 1))]), "messages.getMessages", nil),
    Case(TL.Updates.GetState(), "updates.getState", nil),
  ]

  @Test("the method and its leading peer, without access hashes or text", arguments: cases)
  func describesKnownRequests(_ expected: Case) {
    let summary = RPCRequestSummary.describe(expected.function)
    #expect(summary.name == expected.name)
    #expect(summary.peer == expected.peer)
    #expect(summary.peer?.contains(String(Self.hash)) != true)
  }

  @Test("a wrapped request is described as the request it carries")
  func wrappersAreSeenThrough() {
    let send = TL.Messages.SendMessage(peer: Self.channel, message: "PRIVATE", randomId: 1)
    let summary = RPCRequestSummary.describe(
      TL.InvokeWithLayer(
        layer: TelegramSchemaLayer.current,
        query: TL.InitConnection(
          apiId: 1, deviceModel: "d", systemVersion: "s", appVersion: "a", systemLangCode: "en",
          langPack: "", langCode: "en", query: TL.InvokeWithoutUpdates(query: send))))
    #expect(summary.name == "messages.sendMessage")
    #expect(summary.peer == "channel:42")
  }

  @Test("any other method is named, with no peer")
  func otherMethodsAreNamed() {
    let history = TL.Messages.GetHistory(
      peer: Self.channel, offsetId: 0, offsetDate: 0, addOffset: 0, limit: 1, maxId: 0, minId: 0,
      hash: 0)
    let summary = RPCRequestSummary.describe(history)
    #expect(summary.name == "messages.getHistory")
    #expect(summary.peer == nil)
  }
}
