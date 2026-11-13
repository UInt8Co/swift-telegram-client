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

  private static func container(_ user: TL.UserType, seq: Int32) -> TL.UpdatesType {
    .updates(TL.Updates_(updates: [], users: [user], chats: [], date: 1, seq: seq))
  }

  private static let users = [fullUser].tlSerialized()

  private static func client(_ replies: [Data], _ observation: ReceivedPeerObservation) -> TLClient {
    TLClient(transport: PeerObservingTransport(base: CannedTransport(replies), observation: observation))
  }

  private static let getHistory = TL.Messages.GetHistory(
    peer: .inputPeerEmpty(TL.InputPeerEmpty()), offsetId: 0, offsetDate: 0, addOffset: 0,
    limit: 1, maxId: 0, minId: 0, hash: 0)
  private static let getSelf = TL.Users.GetUsers(id: [.inputUserSelf(TL.InputUserSelf())])

  /// An observation with `observer` attached, and a client observed through it.
  private static func observed(
    _ replies: [Data], observer: @escaping ReceivedPeersObserver
  ) async -> (TLClient, ReceivedPeerObservation) {
    let observation = ReceivedPeerObservation()
    await observation.attach(observer)
    return (
      TLClient(transport: PeerObservingTransport(base: CannedTransport(replies), observation: observation)),
      observation
    )
  }

  @Test("a result's peers reach the observer raw, with the call, before the caller has the result")
  func resultPeersPrecedeTheResult() async throws {
    let events = Events()
    let reply = Self.history(users: [Self.minUser, Self.fullUser], chats: [Self.minChannel])
    let (api, _) = await Self.observed([reply]) { peers in
      // Suspends, so a result handed on early would overtake it.
      try await Task.sleep(for: .milliseconds(20))
      events.append(.observed(Seen(peers)))
      let call = try #require(peers.call)
      #expect(call.invokes(TL.Messages.GetHistory.self))
      #expect(!call.invokes(TL.Users.GetUsers.self))
      #expect(call.result is TL.Messages.MessagesType)
      #expect(call.context == nil)
      #expect(call.withholdsResultOnFailure)
    }

    _ = try await api.invoke(Self.getHistory)
    events.append(.returned)

    #expect(
      events.all == [
        .observed(
          Seen(users: [Self.minUser, Self.fullUser], chats: [Self.minChannel], from: "messages.getHistory")),
        .returned,
      ])
  }

  @Test("a caller's context reaches the observer with its call, through child tasks")
  func callerContextIsDelivered() async throws {
    let contexts = Mutex<[String?]>([])
    let users = [Self.fullUser].tlSerialized()
    let (api, _) = await Self.observed([users, users, users, users]) { peers in
      contexts.withLock { $0.append(peers.call?.context as? String) }
    }
    _ = try await api.invoke(Self.getSelf)
    try await ReceivedPeers.withContext("outer") {
      _ = try await api.invoke(Self.getSelf)
      try await ReceivedPeers.withContext("inner") { _ = try await api.invoke(Self.getSelf) }
      async let child = api.invoke(Self.getSelf)
      _ = try await child
    }
    #expect(contexts.withLock { $0 } == [nil, "outer", "inner", "outer"])
  }

  @Test("a full-information reply is told apart by its result type, not its method name")
  func fullInfoRepliesAreTyped() async throws {
    let full = TL.Users.UserFull(
      fullUser: TL.UserFull(
        id: 8, settings: TL.PeerSettings(), notifySettings: TL.PeerNotifySettings(),
        commonChatsCount: 0),
      chats: [], users: [Self.fullUser])
    let seen = Mutex<[Bool]>([])
    let (api, _) = await Self.observed([full.tlSerialized()]) { peers in
      seen.withLock { $0.append(peers.call?.result is TL.Users.UserFull) }
    }
    _ = try await api.users.getFullUser(id: .inputUserSelf(TL.InputUserSelf()))
    #expect(seen.withLock { $0 } == [true])
  }

  @Test("a result without peers, or of a method that cannot carry one, is not observed")
  func peerlessResultsAreNotObserved() async throws {
    let events = Events()
    let notModified = TL.Messages.MessagesType.messagesNotModified(
      TL.Messages.MessagesNotModified(count: 3)
    ).tlSerialized()
    let empty = Self.history(users: [], chats: [])
    let (api, _) = await Self.observed([notModified, empty, true.tlSerialized()]) {
      events.append(.observed(Seen($0)))
    }
    _ = try await api.invoke(Self.getHistory)
    _ = try await api.invoke(Self.getHistory)
    _ = try await api.invoke(
      TL.Messages.SetTyping(
        peer: .inputPeerEmpty(TL.InputPeerEmpty()),
        action: .sendMessageCancelAction(TL.SendMessageCancelAction())))
    #expect(events.all.isEmpty)
  }

  @Test("a refusing observer withholds a waited-for result and says the call was executed")
  func observerFailureWithholdsTheResult() async throws {
    struct StoreDown: Error {}
    let (api, _) = await Self.observed([Self.history(users: [Self.fullUser], chats: [])]) { _ in
      throw StoreDown()
    }
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
    let (api, _) = await Self.observed([Self.history(users: [Self.fullUser], chats: [])]) { _ in
      throw CancellationError()
    }
    await #expect(throws: CancellationError.self) { _ = try await api.invoke(Self.getHistory) }
  }

  @Test("a method sent inside wrappers is observed as itself")
  func wrappedMethodsAreObserved() async throws {
    let events = Events()
    let users = [Self.fullUser].tlSerialized()
    let invoked = Mutex<[ObjectIdentifier]>([])
    let (api, _) = await Self.observed([users, users]) { peers in
      events.append(.observed(Seen(peers)))
      if let call = peers.call { invoked.withLock { $0.append(ObjectIdentifier(call.function)) } }
    }

    let returned = try await api.invoke(TL.InvokeWithoutUpdates(query: Self.getSelf))
    #expect(returned == [Self.fullUser])
    // Every optional field of `initConnection` present, so each is stepped over.
    _ = try await api.invoke(
      TL.InvokeWithLayer(
        layer: TelegramSchemaLayer.current,
        query: TL.InitConnection(
          apiId: 1, deviceModel: "d", systemVersion: "s", appVersion: "a", systemLangCode: "en",
          langPack: "", langCode: "en", proxy: TL.InputClientProxy(address: "proxy", port: 443),
          params: .jsonObject(
            TL.JsonObject(value: [TL.JsonObjectValue(key: "k", value: .jsonNull(TL.JsonNull()))])),
          query: TL.InvokeAfterMsgs(msgIds: [1, 2], query: Self.getSelf))))

    let expected = Seen(users: [Self.fullUser], chats: [], from: "users.getUsers")
    #expect(events.all == [.observed(expected), .observed(expected)])
    let getUsers = ObjectIdentifier(TL.Users.GetUsers.self)
    #expect(invoked.withLock { $0 } == [getUsers, getUsers], "the call is the wrapped request type")
  }

  @Test("an observed result is decoded once, by the bottom transport, and handed on as observed")
  func observedResultIsDecodedOnce() async throws {
    let observedResults = Mutex<[CountedUsers]>([])
    let (api, _) = await Self.observed([[Self.fullUser].tlSerialized()]) { peers in
      if let result = peers.call?.result as? CountedUsers {
        observedResults.withLock { $0.append(result) }
      }
    }

    let result = try await api.invoke(GetCountedUsers())

    #expect(result.users == [Self.fullUser])
    #expect(CountedUsers.decodes.withLock { $0 } == 1, "decoded once, at the bottom")
    // The observer saw that very decoding, not one of its own.
    #expect(observedResults.withLock { $0 }.map(\.decoding) == [result.decoding])
  }

  @Test("a reply that does not decode fails its call, unobserved")
  func undecodableReplyFails() async throws {
    let events = Events()
    let (api, _) = await Self.observed([Data([1, 2, 3])]) { events.append(.observed(Seen($0))) }
    await #expect(throws: (any Error).self) { _ = try await api.invoke(Self.getSelf) }
    #expect(events.all.isEmpty)
  }

  @Test("pushes are observed and handed on in order; a refused push is reported and still handed on")
  func pushesAreObservedInOrder() async throws {
    struct StoreDown: Error {}
    let events = Events()
    let refused = TL.UserType.user(TL.User(id: 13))
    let short = TL.UpdatesType.updateShortMessage(
      TL.UpdateShortMessage(id: 1, userId: 99, message: "hi", pts: 1, ptsCount: 1, date: 1))
    let observation = ReceivedPeerObservation(onFailure: { failure in
      events.append(.failed(Seen(failure.peers), failure.error is StoreDown))
    })
    await observation.attach { peers in
      if peers.users == [refused] { throw StoreDown() }
      // Later pushes are queued behind this one, not raced past it.
      try await Task.sleep(for: .milliseconds(peers.users == [Self.fullUser] ? 30 : 0))
      events.append(.observed(Seen(peers)))
    }
    let handOn: @Sendable (TL.UpdatesType) -> Void = { events.append(.pushed($0)) }

    observation.push(Self.container(Self.fullUser, seq: 1), handingOnTo: handOn)
    observation.push(Self.container(refused, seq: 2), handingOnTo: handOn)
    observation.push(short, handingOnTo: handOn)
    observation.push(Self.container(Self.minUser, seq: 3), handingOnTo: handOn)
    await observation.flush()

    #expect(
      events.all == [
        .observed(Seen(users: [Self.fullUser], chats: [], from: nil)),
        .pushed(Self.container(Self.fullUser, seq: 1)),
        // Not lost: reported with its peers, then handed on all the same.
        .failed(Seen(users: [refused], chats: [], from: nil), true),
        .pushed(Self.container(refused, seq: 2)),
        // The short form carries no peer object, so there is nothing to observe.
        .pushed(short),
        .observed(Seen(users: [Self.minUser], chats: [], from: nil)),
        .pushed(Self.container(Self.minUser, seq: 3)),
      ])
  }

  @Test("before attachment, results return at once and everything is held, in order, until attached")
  func lateAttachmentDeliversWhatWasHeld() async throws {
    let events = Events()
    let observation = ReceivedPeerObservation()
    let api = TLClient(
      transport: PeerObservingTransport(
        base: CannedTransport([[Self.fullUser].tlSerialized()]), observation: observation))
    let handOn: @Sendable (TL.UpdatesType) -> Void = { events.append(.pushed($0)) }

    observation.push(Self.container(Self.minUser, seq: 1), handingOnTo: handOn)
    _ = try await api.invoke(Self.getSelf)
    events.append(.returned)
    observation.push(Self.container(Self.fullUser, seq: 2), handingOnTo: handOn)
    // Nothing was observed or handed on: there is no observer yet.
    #expect(events.all == [.returned])

    let withheld = Mutex<[Bool]>([])
    await observation.attach { peers in
      withheld.withLock { $0.append(peers.call?.withholdsResultOnFailure ?? false) }
      events.append(.observed(Seen(peers)))
    }
    #expect(
      events.all == [
        .returned,
        .observed(Seen(users: [Self.minUser], chats: [], from: nil)),
        .pushed(Self.container(Self.minUser, seq: 1)),
        .observed(Seen(users: [Self.fullUser], chats: [], from: "users.getUsers")),
        .observed(Seen(users: [Self.fullUser], chats: [], from: nil)),
        .pushed(Self.container(Self.fullUser, seq: 2)),
      ])
    // The held result's caller had it long ago: its failure could withhold nothing.
    #expect(withheld.withLock { $0 } == [false, false, false])
  }

  @Test("a result arriving while held peers are observed waits behind them")
  func resultsWaitBehindTheHeldBacklog() async throws {
    let events = Events()
    let observation = ReceivedPeerObservation()
    let (entered, enter) = AsyncStream.makeStream(of: Void.self)
    let (gate, open) = AsyncStream.makeStream(of: Void.self)
    let calls = Mutex(0)
    let users = [Self.fullUser].tlSerialized()
    let api = TLClient(
      transport: PeerObservingTransport(base: CannedTransport([users, users]), observation: observation))
    _ = try await api.invoke(Self.getSelf)  // held

    let attached = Task {
      await observation.attach { peers in
        if calls.withLock({ $0 += 1; return $0 }) == 1 {
          // The held result: blocks until the test lets it finish.
          enter.yield()
          var iterator = gate.makeAsyncIterator()
          await iterator.next()
        }
        events.append(.observed(Seen(peers)))
      }
    }
    var iterator = entered.makeAsyncIterator()
    await iterator.next()
    let call = Task {
      _ = try await api.invoke(Self.getSelf)
      events.append(.returned)
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(events.all.isEmpty, "the new result overtook the held one")
    open.yield()
    await attached.value
    try await call.value
    let seen = Seen(users: [Self.fullUser], chats: [], from: "users.getUsers")
    #expect(events.all == [.observed(seen), .observed(seen), .returned])
  }

  // MARK: Re-entrancy and ordering

  @Test("an RPC made while a push is observed is observed and returned, not queued behind it")
  func rpcFromAPushObserverCompletes() async throws {
    let observation = ReceivedPeerObservation()
    let api = Self.client([Self.users, Self.users], observation)
    let events = Events()
    await observation.attach { peers in
      if peers.pushed != nil { _ = try await api.invoke(Self.getSelf) }
      events.append(.observed(Seen(peers)))
    }
    try await within("a push whose observer makes an RPC") {
      observation.push(Self.container(Self.minUser, seq: 1)) { events.append(.pushed($0)) }
      await observation.flush()
    }
    #expect(
      events.all == [
        .observed(Seen(users: [Self.fullUser], chats: [], from: "users.getUsers")),
        .observed(Seen(users: [Self.minUser], chats: [], from: nil)),
        .pushed(Self.container(Self.minUser, seq: 1)),
      ])
  }

  @Test("an RPC made while the held backlog is observed completes, and attachment with it")
  func rpcFromTheBacklogObserverCompletes() async throws {
    let observation = ReceivedPeerObservation()
    let api = Self.client([Self.users, Self.users, Self.users], observation)
    let events = Events()
    _ = try await api.invoke(Self.getSelf)  // held
    observation.push(Self.container(Self.minUser, seq: 1)) { events.append(.pushed($0)) }
    try await within("attachment whose backlog observer makes RPCs") {
      await observation.attach { peers in
        // Both a held result's and a held push's observation make an RPC.
        if peers.call?.withholdsResultOnFailure == false || peers.pushed != nil {
          _ = try await api.invoke(Self.getSelf)
        }
        events.append(.observed(Seen(peers)))
      }
    }
    let result = Seen(users: [Self.fullUser], chats: [], from: "users.getUsers")
    #expect(
      events.all == [
        .observed(result), .observed(result),
        .observed(result), .observed(Seen(users: [Self.minUser], chats: [], from: nil)),
        .pushed(Self.container(Self.minUser, seq: 1)),
      ])
  }

  @Test("RPCs nested several observations deep, and from child tasks, complete")
  func nestedAndChildTaskRPCsComplete() async throws {
    let observation = ReceivedPeerObservation()
    let api = Self.client(Array(repeating: Self.users, count: 10), observation)
    let depths = Mutex<[Int]>([])
    await observation.attach { peers in
      let depth = peers.pushed != nil ? -1 : (peers.call?.context as? Int ?? 0)
      depths.withLock { $0.append(depth) }
      guard depth < 3 else { return }
      try await ReceivedPeers.withContext(depth + 1) {
        _ = try await api.invoke(Self.getSelf)
        if depth == 0 {
          // From child tasks the observer awaits, structured and not.
          async let child = api.invoke(Self.getSelf)
          _ = try await child
          try await Task { _ = try await api.invoke(Self.getSelf) }.value
        }
      }
    }
    try await within("RPCs nested inside a push's observation") {
      observation.push(Self.container(Self.minUser, seq: 1)) { _ in }
      await observation.flush()
    }
    // The push (-1) made the depth-0 call, which nested to depth 3, then made
    // two more depth-1 calls from child tasks, each nesting on to depth 3.
    #expect(depths.withLock { $0 } == [-1, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3])
  }

  @Test("a reply does not wait behind pushes received after attachment")
  func repliesDoNotWaitBehindPushes() async throws {
    let observation = ReceivedPeerObservation()
    let api = Self.client([Self.users], observation)
    let (entered, enter) = AsyncStream.makeStream(of: Void.self)
    let (gate, open) = AsyncStream.makeStream(of: Void.self)
    let events = Events()
    await observation.attach { peers in
      if peers.pushed != nil {
        enter.yield()
        var iterator = gate.makeAsyncIterator()
        await iterator.next()
      }
      events.append(.observed(Seen(peers)))
    }
    observation.push(Self.container(Self.minUser, seq: 1)) { events.append(.pushed($0)) }
    observation.push(Self.container(Self.minUser, seq: 2)) { events.append(.pushed($0)) }
    var iterator = entered.makeAsyncIterator()
    await iterator.next()
    // The first push is mid-observation and another waits behind it.
    try await within("a reply while pushes are being observed") {
      _ = try await api.invoke(Self.getSelf)
    }
    #expect(events.all == [.observed(Seen(users: [Self.fullUser], chats: [], from: "users.getUsers"))])
    open.yield()
    open.yield()
    try await within("the pushes after their observer resumed") { await observation.flush() }
    #expect(events.all.count == 5)
  }

  @Test("a caller cancelled while its result waits for the backlog stops waiting; its peers are held")
  func cancelledWaitingCallerHoldsItsPeers() async throws {
    let observation = ReceivedPeerObservation()
    let api = Self.client([Self.users, Self.users], observation)
    let (entered, enter) = AsyncStream.makeStream(of: Void.self)
    let (gate, open) = AsyncStream.makeStream(of: Void.self)
    let observed = Mutex<[Bool]>([])
    _ = try await api.invoke(Self.getSelf)  // held, and blocks the backlog below
    let attached = Task {
      await observation.attach { peers in
        if observed.withLock({ $0.isEmpty }) {
          enter.yield()
          var iterator = gate.makeAsyncIterator()
          await iterator.next()
        }
        observed.withLock { $0.append(peers.call?.withholdsResultOnFailure ?? true) }
      }
    }
    var iterator = entered.makeAsyncIterator()
    await iterator.next()
    let waiting = Task { _ = try await api.invoke(Self.getSelf) }
    try await Task.sleep(for: .milliseconds(30))
    waiting.cancel()
    let outcome = try await within("a cancelled caller") { await waiting.result }
    #expect(throws: CancellationError.self) { try outcome.get() }
    open.yield()
    try await within("attachment after the cancellation") { await attached.value }
    try await within("the cancelled result's peers") { await observation.flush() }
    // The held result, then the cancelled one's peers, held too.
    #expect(observed.withLock { $0 } == [false, false])
  }

  @Test("a held result whose observation fails is reported with its peers")
  func heldFailuresAreReported() async throws {
    struct StoreDown: Error {}
    let failures = Mutex<[Seen]>([])
    let observation = ReceivedPeerObservation(onFailure: { failure in
      failures.withLock { $0.append(Seen(failure.peers)) }
    })
    let api = TLClient(
      transport: PeerObservingTransport(
        base: CannedTransport([[Self.fullUser].tlSerialized()]), observation: observation))
    _ = try await api.invoke(Self.getSelf)
    await observation.attach { _ in throw StoreDown() }
    #expect(failures.withLock { $0 } == [Seen(users: [Self.fullUser], chats: [], from: "users.getUsers")])
  }

  @Test("a peer nested in an update is found in a push")
  func nestedPushPeers() {
    let page = TL.Page(
      url: "https://t.me/iv",
      blocks: [.pageBlockChannel(TL.PageBlockChannel(channel: Self.minChannel))],
      photos: [], documents: [])
    let webpage = TL.WebPageType.webPage(
      TL.WebPage(id: 1, url: "https://t.me/iv", displayUrl: "t.me/iv", hash: 0, cachedPage: page))
    let push = TL.UpdatesType.updateShort(
      TL.UpdateShort(
        update: .updateWebPage(TL.UpdateWebPage(webpage: webpage, pts: 1, ptsCount: 1)), date: 1))
    let peers = ReceivedPeers(pushed: push)
    #expect(Seen(peers) == Seen(users: [], chats: [Self.minChannel], from: nil))
    #expect(peers.pushed == push)
  }
}

// MARK: - Doubles

/// A function whose result counts every time it is decoded; used by one test only.
private struct GetCountedUsers: TLFunction {
  typealias ReturnType = CountedUsers
  static var tlMethodName: String { "test.getCountedUsers" }
  func tlEncode(to writer: inout TLWriter) { writer.writeUInt32(0x7e57_0001) }
}

/// A user vector that records which decoding produced it.
private struct CountedUsers: TLDecodable, Sendable, ReceivedPeerCarrying {
  static let decodes = Mutex(0)
  var users: [TL.UserType]
  /// The ordinal of the decoding that produced this value.
  var decoding: Int

  init(tlFrom reader: inout TLReader) throws {
    users = try [TL.UserType](tlFrom: &reader)
    decoding = Self.decodes.withLock {
      $0 += 1
      return $0
    }
  }

  func collectReceivedPeers(into peers: inout ReceivedPeerList) {
    users.collectReceivedPeers(into: &peers)
  }
}

/// What an observation saw, comparably: the peers and the method, or `nil` for a push.
struct Seen: Equatable, Sendable {
  var users: [TL.UserType]
  var chats: [TL.ChatType]
  var from: String?

  init(users: [TL.UserType], chats: [TL.ChatType], from: String?) {
    self.users = users
    self.chats = chats
    self.from = from
  }

  init(_ peers: ReceivedPeers) {
    self.init(users: peers.users, chats: peers.chats, from: peers.call?.method)
  }
}

private enum Event: Equatable, Sendable {
  case observed(Seen)
  case failed(Seen, Bool)
  case pushed(TL.UpdatesType)
  case returned
}

private final class Events: Sendable {
  private let events = Mutex<[Event]>([])
  func append(_ event: Event) { events.withLock { $0.append(event) } }
  var all: [Event] { events.withLock { $0 } }
}

private struct TimedOut: Error {}

/// Runs `operation` unstructured, so a hang fails the test after `seconds`
/// instead of hanging the run.
private func within<T: Sendable>(
  _ what: String, seconds: Double = 5, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let (outcomes, outcome) = AsyncStream.makeStream(of: Result<T, any Error>?.self)
  let task = Task {
    do { outcome.yield(.success(try await operation())) } catch { outcome.yield(.failure(error)) }
  }
  let timer = Task {
    try? await Task.sleep(for: .seconds(seconds))
    outcome.yield(nil)
  }
  var iterator = outcomes.makeAsyncIterator()
  let first = await iterator.next() ?? nil
  timer.cancel()
  guard let first else {
    task.cancel()
    Issue.record("timed out: \(what)")
    throw TimedOut()
  }
  return try first.get()
}
