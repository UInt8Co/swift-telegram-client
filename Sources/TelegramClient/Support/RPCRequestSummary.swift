import TLCoding
import TelegramSchema

/// Payload-free names for RPC requests, for logs and flood bookkeeping.
public enum RPCRequestSummary {
  /// The TL method a request invokes and the peer it addresses, if it leads with
  /// one.
  ///
  /// The method is the innermost function, looking through `invokeWith…`
  /// wrappers, so `invokeWithoutUpdates(messages.sendMessage(…))` is named
  /// `messages.sendMessage`. The peer is `user:ID`, `channel:ID`, `chat:ID` or
  /// `self`, and a list of peers names its first and appends ` (+N peers)`. It is
  /// read only for methods known to lead with a peer, and is `nil` for every
  /// other method and for a peer addressed through a message (`…FromMessage`) or
  /// left empty — the caller's context names those instead. Access hashes and
  /// message text are never read. No I/O or cancellation is involved.
  public static func describe(_ function: some TLFunction) -> (name: String, peer: String?) {
    let innermost = function.tlInnermostFunction
    let peer = (innermost as? any RPCLeadingPeerRequest)?.leadingPeerSummary
    return (type(of: innermost).tlMethodName, peer)
  }
}

/// A request whose leading argument names the peer it addresses.
///
/// The peer is diagnostic only: for a method with two, it is the one written
/// first (`messages.forwardMessages` names its source, `channels.editBanned` its
/// channel), and an ephemeral message without a peer names its receiver.
protocol RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { get }
}

/// Formats input peers for ``RPCRequestSummary`` without their access hashes.
enum RPCPeerSummary {
  static func of(_ peer: TL.InputPeerType) -> String? {
    switch peer {
    case .inputPeerSelf: "self"
    case .inputPeerUser(let user): "user:\(user.userId)"
    case .inputPeerChannel(let channel): "channel:\(channel.channelId)"
    case .inputPeerChat(let chat): "chat:\(chat.chatId)"
    // Addressed through a message, or nobody: the caller's context names it.
    case .inputPeerEmpty, .inputPeerUserFromMessage, .inputPeerChannelFromMessage: nil
    }
  }

  static func of(_ user: TL.InputUserType) -> String? {
    switch user {
    case .inputUserSelf: "self"
    case .inputUser(let user): "user:\(user.userId)"
    case .inputUserEmpty, .inputUserFromMessage: nil
    }
  }

  static func of(_ channel: TL.InputChannelType) -> String? {
    switch channel {
    case .inputChannel(let channel): "channel:\(channel.channelId)"
    case .inputChannelEmpty, .inputChannelFromMessage: nil
    }
  }

  static func chat(_ id: Int64) -> String { "chat:\(id)" }

  /// The first of `peers`, counting the rest: `user:7 (+2 peers)`. `nil` for an
  /// empty list or a first peer that has no summary.
  static func first<Peer>(of peers: [Peer], _ summary: (Peer) -> String?) -> String? {
    guard let first = peers.first, let named = summary(first) else { return nil }
    return peers.count > 1 ? named + " (+\(peers.count - 1) peers)" : named
  }
}

// MARK: - Requests that lead with a peer

extension TL.Channels.DeleteMessages: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(channel) }
}
extension TL.Channels.EditBanned: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(channel) }
}
extension TL.Channels.GetChannels: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.first(of: id, RPCPeerSummary.of) }
}
extension TL.Channels.GetFullChannel: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(channel) }
}
extension TL.Channels.GetMessages: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(channel) }
}
extension TL.Channels.GetParticipant: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(channel) }
}
extension TL.Channels.GetParticipants: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(channel) }
}
extension TL.Ephemeral.DeleteMessage: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? {
    if let peer { RPCPeerSummary.of(peer) } else { RPCPeerSummary.of(receiverId) }
  }
}
extension TL.Ephemeral.EditMessage: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? {
    if let peer { RPCPeerSummary.of(peer) } else { RPCPeerSummary.of(receiverId) }
  }
}
extension TL.Ephemeral.SendMessage: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? {
    if let peer { RPCPeerSummary.of(peer) } else { RPCPeerSummary.of(receiverId) }
  }
}
extension TL.Messages.CreateForumTopic: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.DeleteChatUser: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.chat(chatId) }
}
extension TL.Messages.DeleteTopicHistory: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.EditForumTopic: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.EditMessage: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.ForwardMessages: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(fromPeer) }
}
extension TL.Messages.GetChats: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.first(of: id, RPCPeerSummary.chat) }
}
extension TL.Messages.GetForumTopicsByID: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.GetFullChat: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.chat(chatId) }
}
extension TL.Messages.HideChatJoinRequest: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.SendMedia: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.SendMessage: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.SetTyping: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.UpdatePinnedMessage: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Messages.UploadMedia: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Payments.BotCancelStarsSubscription: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(userId) }
}
extension TL.Payments.GetSavedStarGifts: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(peer) }
}
extension TL.Payments.RefundStarsCharge: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(userId) }
}
extension TL.Updates.GetChannelDifference: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(channel) }
}
extension TL.Users.GetFullUser: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.of(id) }
}
extension TL.Users.GetUsers: RPCLeadingPeerRequest {
  var leadingPeerSummary: String? { RPCPeerSummary.first(of: id, RPCPeerSummary.of) }
}
