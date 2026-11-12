import TLCoding
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The users and chats one received value carried, exactly as Telegram sent them.
///
/// Telegram never answers an access hash on its own: a peer's hash arrives inside
/// whatever happens to mention the peer — the `users`/`chats` of an RPC result or
/// an update container, a channel block of an instant-view page, the bot of a
/// login-URL request, a chat invite's chat. Every such position the schema has is
/// read, at any depth, so a value with a peer in it is never handed on without
/// its peers being here first.
///
/// The objects are not merged, deduplicated or cleaned up. The same peer can be
/// listed twice — once in a result's `users` and again inside a message — and a
/// `min` object (`TL.User.min`, `TL.Channel.min`) carries a hash that only
/// addresses the peer in the context it came with. A store must therefore never
/// let a `min` object replace a hash it learned from a full one.
/// <https://core.telegram.org/api/min>
public struct ReceivedPeers: Sendable, Equatable {
  /// Where the peers were received.
  public enum Origin: Sendable, Equatable {
    /// An `Updates` container the server pushed outside any RPC.
    case push
    /// The result of an RPC, by TL method name (`messages.getHistory`). A method
    /// sent inside a wrapper (`invokeWithoutUpdates`, …) is named itself.
    case result(method: String)
  }

  /// Every `User` in the value, in the order the value lists them.
  public var users: [TL.UserType]
  /// Every `Chat` in the value, in the order the value lists them.
  public var chats: [TL.ChatType]
  public var origin: Origin

  public init(users: [TL.UserType], chats: [TL.ChatType], origin: Origin) {
    self.users = users
    self.chats = chats
    self.origin = origin
  }

  /// The peers in a pushed container, including those nested in its updates.
  ///
  /// Of the short forms, only `updateShort` can carry a peer, and only nested in
  /// its one update; `updateShortMessage`, `updateShortChatMessage` and
  /// `updateShortSentMessage` name their peers by id alone, with no object and so
  /// no hash. A sender unknown to the receiver is a reason to fetch the
  /// difference, which returns the objects; this never invents them.
  /// <https://core.telegram.org/api/updates#recovering-gaps>
  public init(pushed updates: TL.UpdatesType) {
    var list = ReceivedPeerList()
    updates.collectReceivedPeers(into: &list)
    self.init(users: list.users, chats: list.chats, origin: .push)
  }

  /// Whether nothing was received.
  public var isEmpty: Bool { users.isEmpty && chats.isEmpty }
}

/// Handed every user and chat a connection receives, before what carried them is
/// handed on: pass one to `TelegramConnection.connect(…, onReceivedPeers:)`.
public typealias ReceivedPeersObserver = @Sendable (ReceivedPeers) async throws -> Void

/// An RPC's result arrived but the ``ReceivedPeersObserver`` refused its peers, so
/// the result was withheld from the caller.
///
/// **The server has already executed the call.** A caller that retries on this
/// error repeats a call that succeeded — a sent message is sent twice — so treat
/// it as an unknown outcome, not as a failed request.
public struct PeerObservationFailure: Error, CustomStringConvertible {
  /// The TL method whose result was withheld.
  public var method: String
  /// What the observer threw.
  public var underlying: any Error

  public init(method: String, underlying: any Error) {
    self.method = method
    self.underlying = underlying
  }

  public var description: String {
    "the result of \(method) arrived, but recording its peers failed: \(underlying)"
  }
}

/// A transport that hands every user and chat in an RPC result to an observer,
/// and returns the result only after the observer has returned.
///
/// ``TelegramConnection`` installs this under its ``TelegramConnection/api``
/// when it is given an observer, so a caller that only uses a connection never
/// builds one. It is public for a client built over another transport — a test
/// double, or a decorator of a connection's transport — that must observe the
/// same way.
///
/// The request's constructor number says what its result decodes to; a wrapper
/// (`invokeWithoutUpdates`, `invokeWithLayer`, …) is stepped into to find the
/// method it carries. Every method of ``TelegramSchema`` whose result can hold a
/// peer is known (`Scripts/generate-received-peers.ts`); a method from another
/// schema generated on top of it is passed through unobserved.
///
/// A result is decoded once here and again by `TLClient`: the transport hands
/// over bytes and receives bytes, so the decoded value cannot be shared. A
/// result that does not decode here is passed on untouched, and `TLClient` fails
/// it with the same error.
///
/// The observer runs on the caller's task, so concurrent calls observe
/// concurrently, and a slow observer delays exactly the calls whose results it is
/// observing. If it throws, the call fails with ``PeerObservationFailure`` — or
/// with the `CancellationError` it threw — instead of returning a result whose
/// peers were not recorded.
public struct PeerObservingTransport: TLClientTransport {
  public let base: any TLClientTransport
  private let observer: ReceivedPeersObserver

  public init(base: any TLClientTransport, observer: @escaping ReceivedPeersObserver) {
    self.base = base
    self.observer = observer
  }

  public func send(_ requestBody: Data) async throws -> Data {
    let reply = try await base.send(requestBody)
    guard let reader = ReceivedPeerReplies.reader(forRequest: requestBody),
      let list = try? reader.read(reply), !list.isEmpty
    else { return reply }
    do {
      try await observer(
        ReceivedPeers(users: list.users, chats: list.chats, origin: .result(method: reader.method)))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PeerObservationFailure(method: reader.method, underlying: error)
    }
    return reply
  }
}

/// Hands pushed containers on in arrival order, each only after its peers were
/// observed.
///
/// The server pushes regardless of how fast they are consumed, and the transport
/// delivers them synchronously, so nothing upstream can be slowed down: a slow
/// observer grows this queue, unbounded, rather than losing a push. A push whose
/// observer throws is dropped with a warning. A push is a prompt, never the only
/// copy — the difference carries the same update, with its peers, through an RPC
/// that is observed in turn.
final class PeerObservingPushRelay: Sendable {
  private let continuation: AsyncStream<TL.UpdatesType>.Continuation

  init(
    observer: @escaping ReceivedPeersObserver,
    sink: (@Sendable (TL.UpdatesType) -> Void)?, log: TelegramLog
  ) {
    let (stream, continuation) = AsyncStream.makeStream(of: TL.UpdatesType.self)
    self.continuation = continuation
    Task {
      for await updates in stream {
        let peers = ReceivedPeers(pushed: updates)
        if !peers.isEmpty {
          do {
            try await observer(peers)
          } catch {
            log.warning("dropping a pushed update container: recording its peers failed: \(error)")
            continue
          }
        }
        sink?(updates)
      }
    }
  }

  func push(_ updates: TL.UpdatesType) { continuation.yield(updates) }

  /// Stops after the pushes already queued.
  func finish() { continuation.finish() }

  deinit { continuation.finish() }
}

// MARK: - Reading peers out of values

/// Users and chats gathered from one value.
struct ReceivedPeerList: Equatable {
  var users: [TL.UserType] = []
  var chats: [TL.ChatType] = []

  var isEmpty: Bool { users.isEmpty && chats.isEmpty }
}

/// A TL value that can hold a `User` or a `Chat`. The conformances of schema
/// types are generated (`ReceivedPeers+Schema.swift`); these are the peers
/// themselves and the containers fields wrap them in.
protocol ReceivedPeerCarrying {
  func collectReceivedPeers(into peers: inout ReceivedPeerList)
}

extension TL.UserType: ReceivedPeerCarrying {
  func collectReceivedPeers(into peers: inout ReceivedPeerList) { peers.users.append(self) }
}

extension TL.ChatType: ReceivedPeerCarrying {
  func collectReceivedPeers(into peers: inout ReceivedPeerList) { peers.chats.append(self) }
}

extension Array: ReceivedPeerCarrying where Element: ReceivedPeerCarrying {
  func collectReceivedPeers(into peers: inout ReceivedPeerList) {
    for element in self { element.collectReceivedPeers(into: &peers) }
  }
}

extension Optional: ReceivedPeerCarrying where Wrapped: ReceivedPeerCarrying {
  func collectReceivedPeers(into peers: inout ReceivedPeerList) {
    self?.collectReceivedPeers(into: &peers)
  }
}

/// Which methods' results carry peers, and how to read them from a reply body.
enum ReceivedPeerReplies {
  /// Reads the peers out of one method's reply body, decoding it as the type
  /// `TLClient` will.
  struct Reader: Sendable {
    let method: String
    let read: @Sendable (Data) throws -> ReceivedPeerList

    init<Function: TLFunction>(_: Function.Type, _ method: String)
    where Function.ReturnType: ReceivedPeerCarrying {
      self.method = method
      self.read = { reply in
        var list = ReceivedPeerList()
        try Function.ReturnType(tlData: reply).collectReceivedPeers(into: &list)
        return list
      }
    }
  }

  /// Steps over a wrapper method's fields up to the query it wraps.
  struct Wrapper: Sendable {
    let method: String
    let skip: @Sendable (inout TLReader) throws -> Void

    init(_ method: String, skip: @escaping @Sendable (inout TLReader) throws -> Void) {
      self.method = method
      self.skip = skip
    }
  }

  /// Wrappers nest a handful deep in practice (`invokeWithLayer(initConnection(…))`);
  /// anything deeper is not a request this library builds.
  static let maximumWrapperDepth = 8

  /// The reader for the method `body` invokes, looking through wrappers; `nil`
  /// for a method whose result cannot carry a peer, or one this schema does not
  /// define.
  static func reader(forRequest body: Data) -> Reader? {
    var reader = TLReader(body)
    for _ in 0..<maximumWrapperDepth {
      guard let id = try? reader.readUInt32() else { return nil }
      if let method = methods[id] { return method }
      guard let wrapper = wrappers[id], (try? wrapper.skip(&reader)) != nil else { return nil }
    }
    return nil
  }
}

extension [UInt32: ReceivedPeerReplies.Reader] {
  mutating func add<Function: TLFunction & TLConstructed>(
    _ function: Function.Type, _ method: String
  ) where Function.ReturnType: ReceivedPeerCarrying {
    self[Function.tlConstructorID] = .init(function, method)
  }
}
