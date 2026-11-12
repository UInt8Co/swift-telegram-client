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

@Suite struct ReceivedPeersTests {
  private static let minUser = TL.UserType.user(
    TL.User(min: true, id: 7, accessHash: 777, firstName: "Seen"))
  private static let fullUser = TL.UserType.user(TL.User(id: 8, accessHash: 888))
  private static let minChannel = TL.ChatType.channel(
    TL.Channel(
      megagroup: true, min: true, id: 42, accessHash: 999, title: "Group",
      photo: .chatPhotoEmpty(TL.ChatPhotoEmpty()), date: 1))

  private static func history(users: [TL.UserType], chats: [TL.ChatType]) -> Data {
    TL.Messages.MessagesType.messages(
      TL.Messages.Messages(messages: [], topics: [], chats: chats, users: users)
    ).tlSerialized()
  }

  private static let getHistory = TL.Messages.GetHistory(
    peer: .inputPeerEmpty(TL.InputPeerEmpty()), offsetId: 0, offsetDate: 0, addOffset: 0,
    limit: 1, maxId: 0, minId: 0, hash: 0)

  @Test("a result's peers reach the observer, raw and before the caller has the result")
  func resultPeersPrecedeTheResult() async throws {
    let events = Events()
    let reply = Self.history(users: [Self.minUser, Self.fullUser], chats: [Self.minChannel])
    let api = TLClient(
      transport: PeerObservingTransport(base: CannedTransport([reply])) { peers in
        // Suspends, so a result handed on early would overtake it.
        try await Task.sleep(for: .milliseconds(20))
        events.append(.observed(peers))
      })

    _ = try await api.invoke(Self.getHistory)
    events.append(.returned)

    #expect(
      events.all == [
        .observed(
          ReceivedPeers(
            users: [Self.minUser, Self.fullUser], chats: [Self.minChannel],
            origin: .result(method: "messages.getHistory"))),
        .returned,
      ])
    // `min` and its hash survive untouched.
    guard case .observed(let peers) = events.all.first,
      case .user(let user) = peers.users.first, case .channel(let channel) = peers.chats.first
    else { Issue.record("nothing observed"); return }
    #expect(user.min && user.accessHash == 777)
    #expect(channel.min && channel.accessHash == 999)
  }

  @Test("a result without peers, or of a method that cannot carry one, is not observed")
  func peerlessResultsAreNotObserved() async throws {
    let events = Events()
    let notModified = TL.Messages.MessagesType.messagesNotModified(
      TL.Messages.MessagesNotModified(count: 3)
    ).tlSerialized()
    let empty = Self.history(users: [], chats: [])
    let api = TLClient(
      transport: PeerObservingTransport(
        base: CannedTransport([notModified, empty, true.tlSerialized()])
      ) { events.append(.observed($0)) })

    _ = try await api.invoke(Self.getHistory)
    _ = try await api.invoke(Self.getHistory)
    _ = try await api.invoke(TL.Messages.SetTyping(
      peer: .inputPeerEmpty(TL.InputPeerEmpty()), action: .sendMessageCancelAction(TL.SendMessageCancelAction())))
    #expect(events.all.isEmpty)
  }

  @Test("a refusing observer withholds the result and says the call was executed")
  func observerFailureWithholdsTheResult() async throws {
    struct StoreDown: Error {}
    let reply = Self.history(users: [Self.fullUser], chats: [])
    let api = TLClient(
      transport: PeerObservingTransport(base: CannedTransport([reply])) { _ in throw StoreDown() })
    do {
      _ = try await api.invoke(Self.getHistory)
      Issue.record("the result was handed on")
    } catch let failure as PeerObservationFailure {
      #expect(failure.method == "messages.getHistory")
      #expect(failure.underlying is StoreDown)
    }
  }

  @Test("cancellation inside the observer stays a cancellation")
  func observerCancellationPassesThrough() async throws {
    let reply = Self.history(users: [Self.fullUser], chats: [])
    let api = TLClient(
      transport: PeerObservingTransport(base: CannedTransport([reply])) { _ in
        throw CancellationError()
      })
    await #expect(throws: CancellationError.self) { _ = try await api.invoke(Self.getHistory) }
  }

  @Test("a method sent inside wrappers is observed as itself")
  func wrappedMethodsAreObserved() async throws {
    let events = Events()
    let users = [Self.fullUser].tlSerialized()
    let api = TLClient(
      transport: PeerObservingTransport(base: CannedTransport([users, users])) {
        events.append(.observed($0))
      })
    let getUsers = TL.Users.GetUsers(id: [.inputUserSelf(TL.InputUserSelf())])

    _ = try await api.invoke(TL.InvokeWithoutUpdates(query: getUsers))
    // Every optional field of `initConnection` present, so each is stepped over.
    _ = try await api.invoke(
      TL.InvokeWithLayer(
        layer: TelegramSchemaLayer.current,
        query: TL.InitConnection(
          apiId: 1, deviceModel: "d", systemVersion: "s", appVersion: "a", systemLangCode: "en",
          langPack: "", langCode: "en", proxy: TL.InputClientProxy(address: "proxy", port: 443),
          params: .jsonObject(
            TL.JsonObject(value: [TL.JsonObjectValue(key: "k", value: .jsonNull(TL.JsonNull()))])),
          query: TL.InvokeAfterMsgs(msgIds: [1, 2], query: getUsers))))

    let expected = ReceivedPeers(
      users: [Self.fullUser], chats: [], origin: .result(method: "users.getUsers"))
    #expect(events.all == [.observed(expected), .observed(expected)])
  }

  @Test("pushes are observed and handed on in order; a refused push is dropped")
  func pushesAreObservedInOrder() async throws {
    struct StoreDown: Error {}
    let events = Events()
    let warnings = Mutex<[String]>([])
    let (handedOn, handedOnContinuation) = AsyncStream.makeStream(of: Void.self)
    func container(_ user: TL.UserType, seq: Int32) -> TL.UpdatesType {
      .updates(TL.Updates_(updates: [], users: [user], chats: [], date: 1, seq: seq))
    }
    let refused = TL.UserType.user(TL.User(id: 13))
    let short = TL.UpdatesType.updateShortMessage(
      TL.UpdateShortMessage(id: 1, userId: 99, message: "hi", pts: 1, ptsCount: 1, date: 1))
    let relay = PeerObservingPushRelay(
      observer: { peers in
        if peers.users == [refused] { throw StoreDown() }
        // Later pushes are queued behind this one, not raced past it.
        try await Task.sleep(for: .milliseconds(peers.users == [Self.fullUser] ? 30 : 0))
        events.append(.observed(peers))
      },
      sink: { updates in
        events.append(.pushed(updates))
        handedOnContinuation.yield()
      },
      log: TelegramLog(minimum: .warning) { _, message in warnings.withLock { $0.append(message) } })

    relay.push(container(Self.fullUser, seq: 1))
    relay.push(container(refused, seq: 2))
    relay.push(short)
    relay.push(container(Self.minUser, seq: 3))
    relay.finish()
    var iterator = handedOn.makeAsyncIterator()
    for _ in 0..<3 { await iterator.next() }

    #expect(
      events.all == [
        .observed(ReceivedPeers(users: [Self.fullUser], chats: [], origin: .push)),
        .pushed(container(Self.fullUser, seq: 1)),
        // The short form carries no peer object, so there is nothing to observe.
        .pushed(short),
        .observed(ReceivedPeers(users: [Self.minUser], chats: [], origin: .push)),
        .pushed(container(Self.minUser, seq: 3)),
      ])
    #expect(warnings.withLock { $0.count } == 1)
    #expect(warnings.withLock { $0.first?.contains("dropping a pushed update container") } == true)
  }

  @Test("a peer nested in an update is found in a push")
  func nestedPushPeers() {
    let page = TL.Page(
      url: "https://t.me/iv", blocks: [.pageBlockChannel(TL.PageBlockChannel(channel: Self.minChannel))],
      photos: [], documents: [])
    let webpage = TL.WebPageType.webPage(
      TL.WebPage(id: 1, url: "https://t.me/iv", displayUrl: "t.me/iv", hash: 0, cachedPage: page))
    let push = TL.UpdatesType.updateShort(
      TL.UpdateShort(
        update: .updateWebPage(TL.UpdateWebPage(webpage: webpage, pts: 1, ptsCount: 1)), date: 1))
    #expect(ReceivedPeers(pushed: push) == ReceivedPeers(users: [], chats: [Self.minChannel], origin: .push))
  }
}

// MARK: - Doubles

private enum Event: Equatable, Sendable {
  case observed(ReceivedPeers)
  case pushed(TL.UpdatesType)
  case returned
}

private final class Events: Sendable {
  private let events = Mutex<[Event]>([])
  func append(_ event: Event) { events.withLock { $0.append(event) } }
  var all: [Event] { events.withLock { $0 } }
}
