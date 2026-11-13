import Synchronization
import TLCoding
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The bottom of a test's transport chain, standing in for `TelegramTransport`:
/// records each request as the typed function it is, and answers it with a
/// reply body decoded as the function's result type, as the wire reply would be.
///
/// Every fake transport in this target is one of these, so reply bytes are
/// decoded in exactly one place. Replies are canned in order, or computed per
/// request by `respond`, which may also suspend or throw an RPC error.
final class CannedTransport: TLClientTransport {
  typealias Respond = @Sendable (any TLFunction) async throws -> Data

  private struct State {
    var requests: [any TLFunction] = []
    var decodedReplies = 0
  }

  private let respond: Respond
  private let state = Mutex(State())

  /// Answers each request with the next of `replies`; a request beyond them
  /// fails the test.
  convenience init(_ replies: [Data]) {
    let remaining = Mutex(replies)
    self.init { _ in
      let reply = remaining.withLock { $0.isEmpty ? nil : $0.removeFirst() }
      return try #require(reply, "unexpected request")
    }
  }

  init(respond: @escaping Respond) {
    self.respond = respond
  }

  /// Every request so far, in order.
  var requests: [any TLFunction] { state.withLock { $0.requests } }

  /// The requests so far that invoked `function`, in order.
  func requests<Function: TLFunction>(_ function: Function.Type) -> [Function] {
    requests.compactMap { $0 as? Function }
  }

  /// How many reply bodies were decoded: one per answered request.
  var decodedReplies: Int { state.withLock { $0.decodedReplies } }

  func invoke<Function: TLFunction>(_ function: Function) async throws -> Function.ReturnType {
    state.withLock { $0.requests.append(function) }
    let reply = try await respond(function)
    let result = try Function.ReturnType(tlData: reply)
    state.withLock { $0.decodedReplies += 1 }
    return result
  }
}

extension TLFunction {
  /// The innermost function's TL name, for a fake that answers by method.
  var methodName: String { type(of: tlInnermostFunction).tlMethodName }
}
