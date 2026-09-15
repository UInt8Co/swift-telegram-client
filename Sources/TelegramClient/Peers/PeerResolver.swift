import TelegramSchema

/// Turns a name or an id into something this session can address.
public enum PeerResolver {
  /// Resolves a channel or supergroup.
  ///
  /// A username is resolved by asking; an id needs an access hash, and `lookup`
  /// says where this account's comes from (``PeerLookup``).
  public static func channel(
    _ locator: PeerLocator, lookup: PeerLookup, using api: TLClient
  ) async throws -> ChannelReference {
    switch locator {
    case .username(let username):
      let result = try await api.invoke(TL.Contacts.ResolveUsername(username: username))
      guard case .peerChannel(let peer) = result.peer,
        let chat = result.chats.first(where: { channelID(of: $0) == peer.channelId })
      else { throw TelegramClientError.peerNotFound(locator.description) }
      return try reference(chat, description: locator.description, lookup: lookup)
    case .id(let id):
      switch lookup {
      case .byID:
        let result = try await api.invoke(
          TL.Channels.GetChannels(id: [
            .inputChannel(TL.InputChannel(channelId: id, accessHash: 0))
          ]))
        let chats: [TL.ChatType]
        switch result {
        case .chats(let value): chats = value.chats
        case .chatsSlice(let value): chats = value.chats
        }
        guard let chat = chats.first(where: { channelID(of: $0) == id }) else {
          throw TelegramClientError.peerNotFound(locator.description)
        }
        return try reference(chat, description: locator.description, lookup: lookup)
      case .inDialogs:
        let found = try await inDialogs(api) { page -> ChannelReference? in
          guard let chat = page.chats.first(where: { channelID(of: $0) == id }) else {
            return nil
          }
          return try reference(chat, description: locator.description, lookup: lookup)
        }
        guard let found else { throw TelegramClientError.peerNotFound(locator.description) }
        return found
      }
    }
  }

  /// Resolves a user by id.
  public static func user(
    _ id: Int64, lookup: PeerLookup, using api: TLClient
  ) async throws -> UserReference {
    switch lookup {
    case .byID:
      let users = try await api.invoke(
        TL.Users.GetUsers(id: [.inputUser(TL.InputUser(userId: id, accessHash: 0))]))
      guard case .user(let user) = users.first(where: { userID(of: $0) == id }) else {
        throw TelegramClientError.userNotFound(id)
      }
      // A `min` user's hash is not usable for anything but the context it came
      // in; zero is what a bot sends for such a peer.
      return UserReference(id: id, accessHash: user.min ? 0 : user.accessHash ?? 0)
    case .inDialogs:
      let found = try await inDialogs(api) { page -> UserReference? in
        guard let user = page.users.first(where: { userID(of: $0) == id }) else { return nil }
        guard case .user(let value) = user, let hash = value.accessHash else {
          throw TelegramClientError.missingAccessHash(String(id))
        }
        return UserReference(id: id, accessHash: hash)
      }
      guard let found else { throw TelegramClientError.userNotFound(id) }
      return found
    }
  }

  /// Pages the account's dialog list, handing each page to `found` until it
  /// returns something. `nil` when the list runs out.
  private static func inDialogs<T>(
    _ api: TLClient, found: (DialogPage) throws -> T?
  ) async throws -> T? {
    var offsetDate: Int32 = 0
    var offsetID: Int32 = 0
    var offsetPeer: TL.InputPeerType = .inputPeerEmpty(TL.InputPeerEmpty())
    while true {
      let result = try await api.invoke(
        TL.Messages.GetDialogs(
          offsetDate: offsetDate, offsetId: offsetID, offsetPeer: offsetPeer,
          limit: 100, hash: 0))
      let page: DialogPage
      switch result {
      case .dialogs(let value):
        page = DialogPage(
          dialogs: value.dialogs, messages: value.messages, chats: value.chats,
          users: value.users, terminal: true)
      case .dialogsSlice(let value):
        page = DialogPage(
          dialogs: value.dialogs, messages: value.messages, chats: value.chats,
          users: value.users, terminal: false)
      case .dialogsNotModified:
        return nil
      }
      if let value = try found(page) { return value }
      // The last dialog of the page is the next page's offset. A page that
      // cannot name one, or names the one just used, is the end — a server that
      // keeps answering the same offset would otherwise loop forever.
      guard !page.terminal, !page.dialogs.isEmpty, let next = page.nextOffset(),
        next.date != offsetDate || next.id != offsetID || next.peer != offsetPeer
      else { return nil }
      offsetDate = next.date
      offsetID = next.id
      offsetPeer = next.peer
    }
  }

  /// A broadcast channel or a supergroup, and which of the two it is.
  ///
  /// A basic group keeps no `pts` and answers no channel difference; a monoforum
  /// puts its messages in a correspondent's topic, which an update does not
  /// name. Both are refused here rather than half-supported.
  ///
  /// `channelForbidden` says nothing about topics, which is as much as a peer
  /// the account cannot see says about anything.
  private static func reference(
    _ chat: TL.ChatType, description: String, lookup: PeerLookup
  ) throws -> ChannelReference {
    switch chat {
    case .channel(let channel):
      // A `min` channel's hash names it only inside the message it arrived
      // with; a lookup by id sends zero instead, which is what a bot may do.
      let accessHash =
        lookup == .byID ? (channel.min ? 0 : channel.accessHash ?? 0) : channel.accessHash
      guard let hash = accessHash else {
        throw TelegramClientError.missingAccessHash(description)
      }
      guard !channel.monoforum else {
        throw TelegramClientError.monoforumUnsupported(description)
      }
      return ChannelReference(
        id: channel.id, accessHash: hash, title: channel.title,
        kind: channel.megagroup ? .supergroup : .broadcast, isForum: channel.forum)
    case .channelForbidden(let channel):
      guard !channel.monoforum else {
        throw TelegramClientError.monoforumUnsupported(description)
      }
      return ChannelReference(
        id: channel.id, accessHash: channel.accessHash, title: channel.title,
        kind: channel.megagroup ? .supergroup : .broadcast)
    default:
      throw TelegramClientError.channelRequired(description)
    }
  }

  static func channelID(of chat: TL.ChatType) -> Int64? {
    switch chat {
    case .channel(let channel): channel.id
    case .channelForbidden(let channel): channel.id
    default: nil
    }
  }

  static func userID(of user: TL.UserType) -> Int64? {
    switch user {
    case .user(let user): user.id
    case .userEmpty(let user): user.id
    }
  }

  /// One page of `messages.getDialogs`, and what the next page starts from.
  struct DialogPage {
    var dialogs: [TL.DialogType]
    var messages: [TL.MessageType]
    var chats: [TL.ChatType]
    var users: [TL.UserType]
    var terminal: Bool

    func nextOffset() -> (date: Int32, id: Int32, peer: TL.InputPeerType)? {
      guard case .dialog(let dialog) = dialogs.last,
        let peer = inputPeer(dialog.peer),
        let date = messageDate(id: dialog.topMessage, peer: dialog.peer)
      else { return nil }
      return (date, dialog.topMessage, peer)
    }

    private func inputPeer(_ peer: TL.PeerType) -> TL.InputPeerType? {
      switch peer {
      case .peerChannel(let value):
        guard let chat = chats.first(where: { PeerResolver.channelID(of: $0) == value.channelId })
        else { return nil }
        switch chat {
        case .channel(let channel):
          guard let hash = channel.accessHash else { return nil }
          return .inputPeerChannel(
            TL.InputPeerChannel(channelId: channel.id, accessHash: hash))
        case .channelForbidden(let channel):
          return .inputPeerChannel(
            TL.InputPeerChannel(channelId: channel.id, accessHash: channel.accessHash))
        default: return nil
        }
      case .peerChat(let value):
        return .inputPeerChat(TL.InputPeerChat(chatId: value.chatId))
      case .peerUser(let value):
        guard
          case .user(let user) = users.first(where: {
            PeerResolver.userID(of: $0) == value.userId
          }),
          let hash = user.accessHash
        else { return nil }
        return .inputPeerUser(TL.InputPeerUser(userId: user.id, accessHash: hash))
      }
    }

    private func messageDate(id: Int32, peer: TL.PeerType) -> Int32? {
      for message in messages {
        switch message {
        case .message(let value) where value.id == id && value.peerId == peer: return value.date
        case .messageService(let value) where value.id == id && value.peerId == peer:
          return value.date
        default: continue
        }
      }
      return nil
    }
  }
}
