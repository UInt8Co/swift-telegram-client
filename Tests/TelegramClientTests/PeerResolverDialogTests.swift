import Synchronization
import TLCoding
import TelegramSchema
import Testing

@testable import TelegramClient

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct PeerResolverDialogTests {
  private static func dialogs(
    _ users: [TL.UserType], chats: [TL.ChatType] = [], next: TL.UserType? = nil
  ) -> Data {
    guard case .user(let anchor)? = next else {
      return TL.Messages.DialogsType.dialogs(
        TL.Messages.Dialogs(dialogs: [], messages: [], chats: chats, users: users)
      ).tlSerialized()
    }
    // A slice whose last dialog is `anchor`'s, so the walk continues after it.
    let peer = TL.PeerType.peerUser(TL.PeerUser(userId: anchor.id))
    return TL.Messages.DialogsType.dialogsSlice(
      TL.Messages.DialogsSlice(
        count: 100,
        dialogs: [
          .dialog(
            TL.Dialog(
              peer: peer, topMessage: 10, readInboxMaxId: 0, readOutboxMaxId: 0, unreadCount: 0,
              unreadMentionsCount: 0, unreadReactionsCount: 0, unreadPollVotesCount: 0,
              notifySettings: TL.PeerNotifySettings()))
        ],
        messages: [.message(TL.Message(id: 10, peerId: peer, date: 100, message: ""))],
        chats: chats, users: users + [.user(anchor)])
    ).tlSerialized()
  }

  private static let minUser = TL.UserType.user(TL.User(min: true, id: 7, accessHash: 777))
  private static let anchor = TL.UserType.user(TL.User(id: 8, accessHash: 888))

  @Test("a min user mentioned on a page is passed over for the user's own dialog")
  func minUserIsNotAReference() async throws {
    let transport = CannedTransport([
      Self.dialogs([Self.minUser], next: Self.anchor),
      Self.dialogs([.user(TL.User(id: 7, accessHash: 70))]),
    ])
    let user = try await PeerResolver.user(7, lookup: .inDialogs, using: TLClient(transport: transport))
    #expect(user.accessHash == 70)
    #expect(transport.requests.count == 2)
  }

  @Test("a user seen only as min has no usable hash for a user account")
  func onlyMinUserIsMissingItsHash() async throws {
    let api = TLClient(transport: CannedTransport([Self.dialogs([Self.minUser])]))
    await #expect(throws: TelegramClientError.missingAccessHash("7")) {
      _ = try await PeerResolver.user(7, lookup: .inDialogs, using: api)
    }
  }

  @Test("a channel seen only as min has no usable hash for a user account")
  func onlyMinChannelIsMissingItsHash() async throws {
    let channel = TL.ChatType.channel(
      TL.Channel(
        megagroup: true, min: true, id: 42, accessHash: 999, title: "Group",
        photo: .chatPhotoEmpty(TL.ChatPhotoEmpty()), date: 1))
    let api = TLClient(transport: CannedTransport([Self.dialogs([], chats: [channel])]))
    await #expect(throws: TelegramClientError.missingAccessHash("42")) {
      _ = try await PeerResolver.channel(.id(42), lookup: .inDialogs, using: api)
    }
  }
}

// MARK: - Doubles

/// Answers each request with the next canned reply body.
final class CannedTransport: TLClientTransport {
  private let state: Mutex<(replies: [Data], requests: [Data])>

  init(_ replies: [Data]) { state = Mutex((replies, [])) }

  var requests: [Data] { state.withLock { $0.requests } }

  func send(_ requestBody: Data) async throws -> Data {
    let reply = state.withLock { state -> Data? in
      state.requests.append(requestBody)
      return state.replies.isEmpty ? nil : state.replies.removeFirst()
    }
    return try #require(reply, "unexpected request")
  }
}
