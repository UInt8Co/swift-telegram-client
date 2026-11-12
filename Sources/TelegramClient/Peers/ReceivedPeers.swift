import TLCoding
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The users and chats one received value carried, exactly as Telegram sent them,
/// and what carried them.
///
/// Telegram never answers an access hash on its own: a peer's hash arrives inside
/// whatever happens to mention the peer — the `users`/`chats` of an RPC result or
/// an update container, a channel block of an instant-view page, the bot of a
/// login-URL request, a chat invite's chat. Every such position the schema has is
/// read, at any depth. See <doc:ObservingReceivedPeers>.
///
/// The objects are not merged, deduplicated or cleaned up. The same peer can be
/// listed twice — once in a result's `users` and again inside a message — and a
/// `min` object (`TL.User.min`, `TL.Channel.min`) carries a hash that only
/// addresses the peer in the context it came with. A store must therefore never
/// let a `min` object replace a hash it learned from a full one.
/// <https://core.telegram.org/api/min>
public struct ReceivedPeers: Sendable {
  /// What carried the peers.
  public enum Origin: Sendable {
    /// An `Updates` container the server pushed outside any RPC.
    case push(TL.UpdatesType)
    /// The result of an RPC.
    case result(Call)
  }

  /// One RPC whose result carried peers.
  public struct Call: Sendable {
    /// The TL method's name (`messages.getHistory`), for logs. A method sent
    /// inside a wrapper (`invokeWithoutUpdates`, …) is named itself.
    public var method: String
    /// The request type; ``invokes(_:)`` compares it.
    public var function: any TLFunction.Type
    /// The decoded result the caller receives — a `TL.Users.UserFull`, a
    /// `TL.Messages.MessagesType`, … — to tell what kind of reply it is by type.
    public var result: any Sendable
    /// What the caller attached with ``ReceivedPeers/withContext(_:operation:)``,
    /// or `nil`.
    public var context: (any Sendable)?
    /// Whether throwing from the observer withholds this result from its caller.
    ///
    /// `false` when the caller already had the result before it was observed:
    /// the RPCs a connection makes while connecting, and every result received
    /// before an observer was attached (``ReceivedPeerObservation/attach(_:)``).
    /// A failure to observe those is reported to the observation's failure
    /// handler instead.
    public var withholdsResultOnFailure: Bool

    /// Whether the call was `function`: `call.invokes(TL.Users.GetFullUser.self)`.
    public func invokes(_ function: (some TLFunction).Type) -> Bool {
      ObjectIdentifier(self.function) == ObjectIdentifier(function)
    }

    public init(
      method: String, function: any TLFunction.Type, result: any Sendable,
      context: (any Sendable)? = nil, withholdsResultOnFailure: Bool
    ) {
      self.method = method
      self.function = function
      self.result = result
      self.context = context
      self.withholdsResultOnFailure = withholdsResultOnFailure
    }
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
    self.init(users: list.users, chats: list.chats, origin: .push(updates))
  }

  /// Whether nothing was received.
  public var isEmpty: Bool { users.isEmpty && chats.isEmpty }

  /// The call, for peers that came with an RPC result.
  public var call: Call? {
    if case .result(let call) = origin { call } else { nil }
  }

  /// The pushed container, for peers that came with a push.
  public var pushed: TL.UpdatesType? {
    if case .push(let updates) = origin { updates } else { nil }
  }

  @TaskLocal static var context: (any Sendable)?

  /// Runs `operation` with `context` attached to every RPC it makes, so the
  /// observer of their results receives it as ``Call/context``.
  ///
  /// The context is whatever the consumer wants its observer to know about a
  /// call that the result does not say — that a lookup is not a sighting, that
  /// the caller will report the peers itself. It follows the task, so it reaches
  /// calls made through any transport decorators and through child tasks; an
  /// inner `withContext` replaces an outer one. Pushes have no caller and so no
  /// context.
  public nonisolated(nonsending) static func withContext<Result>(
    _ context: any Sendable, operation: nonisolated(nonsending) () async throws -> Result
  ) async rethrows -> Result {
    try await $context.withValue(context, operation: operation)
  }
}

/// Handed every user and chat a connection receives; see ``ReceivedPeerObservation``.
public typealias ReceivedPeersObserver = @Sendable (ReceivedPeers) async throws -> Void

/// An RPC's result arrived but the ``ReceivedPeersObserver`` refused its peers, so
/// the result was withheld from the caller.
///
/// **The server has already executed the call.** A caller that retries on this
/// error repeats a call that succeeded — a sent message is sent twice — so treat
/// it as an unknown outcome, not as a failed request. An observer that knows the
/// call changed something (from ``ReceivedPeers/Call/function`` or its context)
/// can decline to throw instead.
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
    let function: any TLFunction.Type
    let read: @Sendable (Data) throws -> (peers: ReceivedPeerList, result: any Sendable)

    init<Function: TLFunction>(_: Function.Type, _ method: String)
    where Function.ReturnType: ReceivedPeerCarrying {
      self.method = method
      self.function = Function.self
      self.read = { reply in
        var list = ReceivedPeerList()
        let result = try Function.ReturnType(tlData: reply)
        result.collectReceivedPeers(into: &list)
        return (list, result)
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
