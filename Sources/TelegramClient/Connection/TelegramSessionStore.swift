import MTProtoClientKit
import NIOMTProtoEncryption

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A cached session and the account it authorized.
///
/// The account id is stored with the key because it is the only thing that can
/// tell a resumed session apart from another account's: an auth key carries no
/// name, so a store keyed by anything the caller can get wrong would silently
/// resume the wrong login.
public struct CachedTelegramSession: Equatable, Sendable {
  public var session: MTProtoStoredSession
  public var accountID: Int64

  public init(session: MTProtoStoredSession, accountID: Int64) {
    self.session = session
    self.accountID = accountID
  }
}

/// Where authorized sessions and datacenter lists survive a restart.
///
/// Resuming a session is not an optimization: authorizing again spends a login,
/// which is what earns an application a flood wait, so a client that forgets its
/// key every restart will eventually be told to wait hours. Everything is
/// `async` so a production store can do I/O; ``InMemoryTelegramSessionStore``
/// is enough for tests and for a process that is meant to authorize once.
/// ``FileTelegramSessionStore`` keeps sessions and datacenter lists across
/// restarts in a private directory.
///
/// Keys are opaque strings the client composes from a caller-chosen scope and
/// the datacenter id (``TelegramConnection/sessionKey(scope:dcID:)``): a login
/// authorizes on exactly one datacenter, so a store that ignored the datacenter
/// would hand a migration another datacenter's key.
public protocol TelegramSessionStore: Sendable {
  func session(for key: String) async throws -> CachedTelegramSession?
  func save(_ session: MTProtoStoredSession, accountID: Int64, for key: String) async throws
  func deleteSession(for key: String) async throws

  func datacenterList(for scope: String) async throws -> StoredDatacenterList?
  func saveDatacenterList(_ list: StoredDatacenterList, for scope: String) async throws
}

/// A store that lives and dies with the process. Every session it holds is
/// authorized again on the next run.
public actor InMemoryTelegramSessionStore: TelegramSessionStore {
  private var sessions: [String: CachedTelegramSession] = [:]
  private var datacenterLists: [String: StoredDatacenterList] = [:]

  public init() {}

  public func session(for key: String) async throws -> CachedTelegramSession? {
    sessions[key]
  }

  public func save(
    _ session: MTProtoStoredSession, accountID: Int64, for key: String
  ) async throws {
    sessions[key] = CachedTelegramSession(session: session, accountID: accountID)
  }

  public func deleteSession(for key: String) async throws {
    sessions.removeValue(forKey: key)
  }

  public func datacenterList(for scope: String) async throws -> StoredDatacenterList? {
    datacenterLists[scope]
  }

  public func saveDatacenterList(
    _ list: StoredDatacenterList, for scope: String
  ) async throws {
    datacenterLists[scope] = list
  }
}
