import MTProtoClientKit
import TLCoding

/// An `rpc_error` that carries an instruction rather than a failure:
/// `*_MIGRATE_X` names the datacenter that owns the request, `FLOOD_WAIT_X` how
/// long the caller must wait. Both are obeyed; retrying either one immediately
/// is what turns a redirect into a reconnect loop and a wait into a ban.
public enum MTProtoDirective: Equatable, Sendable {
  case migrate(dcID: Int32)
  case floodWait(seconds: Int64)

  public init?(_ error: any Error) {
    guard let rpc = error as? MTProtoRPCError else { return nil }
    self.init(rpc)
  }

  public init?(_ error: MTProtoRPCError) {
    if let value = Self.suffix(of: error.message, after: Self.migratePrefixes),
      let dcID = Int32(value), dcID > 0
    {
      self = .migrate(dcID: dcID)
    } else if let value = Self.suffix(of: error.message, after: Self.floodPrefixes),
      let seconds = Int64(value), seconds >= 0
    {
      self = .floodWait(seconds: seconds)
    } else {
      return nil
    }
  }

  /// The wait to serve, with a second of margin for the server's own clock.
  public var wait: Duration? {
    guard case .floodWait(let seconds) = self else { return nil }
    return .seconds(seconds + 1)
  }

  private static let migratePrefixes = [
    "USER_MIGRATE_", "PHONE_MIGRATE_", "NETWORK_MIGRATE_", "FILE_MIGRATE_",
    "STATS_MIGRATE_",
  ]
  private static let floodPrefixes = ["FLOOD_WAIT_", "FLOOD_PREMIUM_WAIT_"]

  private static func suffix(of message: String, after prefixes: [String]) -> Substring? {
    for prefix in prefixes where message.hasPrefix(prefix) {
      return message.dropFirst(prefix.count)
    }
    return nil
  }
}

/// Serves `FLOOD_WAIT_X` where it is raised. Every RPC a caller repeats should
/// go through here, because the alternative — letting it reach a reconnect
/// loop — retries the call before the wait has elapsed and earns a longer one.
public enum FloodWait {
  public static func honoring<T>(
    _ label: String, log: TelegramLog = .silent, _ body: () async throws -> T
  ) async throws -> T {
    while true {
      do {
        return try await body()
      } catch {
        guard let wait = MTProtoDirective(error)?.wait else { throw error }
        log.warning("\(label): waiting \(wait) as instructed")
        try await Task.sleep(for: wait)
      }
    }
  }
}

/// An `rpc_error` that says the call did not get to happen this time, rather
/// than that it cannot happen: Telegram answers `-503 Timeout` when its own
/// backend took too long. Nothing about the request is wrong, so the answer to
/// one is to make the call again.
public enum TransientRPCFailure {
  public static func describes(_ error: any Error) -> Bool {
    guard let rpc = error as? MTProtoRPCError else { return false }
    return rpc.code == -503
  }
}

/// Repeats a call the server timed out on. Only for a call that can be made
/// twice without a second effect, which in practice means a read: a send or a
/// mutation repeated after a timeout the server may in fact have served is a
/// duplicate, and those keep using ``FloodWait/honoring(_:log:_:)`` directly.
public enum ServerTimeout {
  /// Attempts in total, counting the first. Two retries is enough for the odd
  /// slow backend and short of waiting on one that is down, which the caller's
  /// own queue or supervisor paces instead.
  public static let attempts = 3

  public static func repeating<T>(
    _ label: String, log: TelegramLog = .silent, _ body: () async throws -> T
  ) async throws -> T {
    var attempt = 1
    while true {
      do {
        return try await FloodWait.honoring(label, log: log, body)
      } catch {
        guard attempt < attempts, TransientRPCFailure.describes(error) else { throw error }
        log.debug("\(label): \(error); asking again")
        // The first ask again is immediate: a backend that gave up on this call
        // has asked for no wait, and the next call usually lands. A second
        // timeout is the service being slow rather than this call being
        // unlucky, and waiting is the only thing left to try.
        if attempt > 1 { try await Task.sleep(for: .seconds(attempt - 1)) }
        attempt += 1
      }
    }
  }
}

/// A reply the connection delivered whole and the schema could not read: a
/// constructor this build has never heard of, bytes that do not decode.
///
/// It is the opposite of a connection failure, and it matters that the two are
/// told apart. Nothing about the link is wrong, so dropping the connection
/// cannot help and reconnecting only reads the same bytes again. What a read
/// does about one is get past it: TL is not self-delimiting, so a value that
/// cannot be decoded cannot be skipped *inside* the reply either, and the unit
/// that has to be given up is whatever the reply covered. A read that can narrow
/// its request should narrow it first, so what is given up is one update rather
/// than a page.
public enum UnreadableReply {
  public static func describes(_ error: any Error) -> Bool {
    error is TLError
  }
}
