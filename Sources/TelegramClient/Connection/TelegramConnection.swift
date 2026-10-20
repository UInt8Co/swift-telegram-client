import MTProtoClientKit
import MTProtoCrypto
import NIOMTProtoEncryption
import Synchronization
import TLCoding
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// How a connection proves who it is.
///
/// An authorization is bound to one datacenter — the one that homes the
/// account — and every other answers `USER_MIGRATE_X` to it. Reaching a second
/// datacenter therefore goes the other way round: the authorized connection
/// exports an authorization *for* that datacenter and the new one imports it.
public enum TelegramAuthorization: Sendable {
  /// Spend a bot token. Only the datacenter that homes the bot accepts it.
  case botToken(String)
  /// Sign a user in interactively — a phone code, or a QR code scanned by an
  /// already–signed-in device. See ``TelegramUserLogin``.
  case user(any TelegramUserLogin)
  /// Import an authorization another connection exports for this datacenter.
  /// The closure runs per dial: an exported authorization is spent by the
  /// import that consumes it, whether or not that import succeeded.
  case exported(@Sendable () async throws -> TL.Auth.ExportedAuthorization)
  /// Resume a stored session and nothing else. A connection with no session in
  /// the cache fails rather than logging in again, which is what a client that
  /// must not spend a second login wants.
  case storedSessionOnly

  /// Whether a `*_MIGRATE_X` answer names an address to follow rather than a
  /// failure to report. An exported authorization already names the datacenter
  /// it was minted for, and a stored session is filed under one.
  var followsMigration: Bool {
    switch self {
    case .botToken, .user: true
    case .exported, .storedSessionOnly: false
    }
  }
}

/// What one dial waits for. These budgets bound each resume attempt; a timeout
/// is a transient failure, never evidence that a stored key has been revoked.
public struct TelegramConnectionTimeouts: Sendable {
  /// The handshake (or resume) becoming usable.
  public var connect: Duration
  /// One RPC answering, including the round trip that proves a resumed session
  /// is still the account's.
  public var request: Duration

  public init(connect: Duration, request: Duration) {
    self.connect = connect
    self.request = request
  }

  public static let `default` = TelegramConnectionTimeouts(
    connect: .seconds(60), request: .seconds(60))
}

/// One authorized MTProto session, and the Telegram API over it.
///
/// ``api`` is the generated client: every RPC in the schema as an `async`
/// function, grouped by TL namespace. Its `invoke` is generic over `TLFunction`,
/// so a schema generated on top of ``TelegramSchema`` — a private namespace a
/// service adds to Telegram's — rides the same connection with no change here.
public final class TelegramConnection: Sendable {
  /// A redirect chain longer than this is a loop, not a migration.
  private static let maximumMigrations = 3

  public let endpoint: TelegramEndpoint
  public let client: MTProtoClient
  /// The user or bot this session acts as.
  public let accountID: Int64
  /// Whether a cached session was resumed instead of a fresh login spent.
  public let resumedSession: Bool
  /// The API layer this connection announced, which is also the layer its
  /// replies and the server's pushes arrive in.
  public let layer: Int32
  /// The Telegram API over this session.
  public let api: TLClient

  private init(
    endpoint: TelegramEndpoint, client: MTProtoClient, transport: TelegramTransport,
    accountID: Int64, resumedSession: Bool
  ) {
    self.endpoint = endpoint
    self.client = client
    self.accountID = accountID
    self.resumedSession = resumedSession
    self.layer = transport.layer
    self.api = TLClient(transport: transport)
  }

  /// Sessions are cached per scope *and* datacenter: a login authorizes on
  /// exactly one datacenter, so a migration must not resume another's key.
  public static func sessionKey(scope: String, dcID: Int32) -> String {
    "\(scope):\(dcID)"
  }

  /// Connects and authorizes, following `*_MIGRATE_X` to the datacenter that
  /// homes the account. `locateDC` supplies the target's addresses; without it
  /// a redirect is an error, and so is one answered to a connection that is not
  /// authorizing with a credential a redirect applies to.
  public static func connect(
    endpoint: TelegramEndpoint, rsaPublicKey: RSAPublicKey, app: TelegramApp,
    layer: Int32, authorization: TelegramAuthorization,
    sessionStore: (any TelegramSessionStore)? = nil, sessionScope: String? = nil,
    locateDC: TelegramDatacenterLocating? = nil,
    onMigration: (@Sendable (Int32) async throws -> Void)? = nil,
    onPushedUpdates: (@Sendable (TL.UpdatesType) -> Void)? = nil,
    timeouts: TelegramConnectionTimeouts = .default,
    log: TelegramLog = .silent
  ) async throws -> TelegramConnection {
    try await connect(
      endpoint: endpoint, rsaPublicKey: rsaPublicKey, app: app, layer: layer,
      authorization: authorization, sessionStore: sessionStore, sessionScope: sessionScope,
      locateDC: locateDC, onMigration: onMigration, onPushedUpdates: onPushedUpdates,
      migrations: 0, timeouts: timeouts, log: log)
  }

  private static func connect(
    endpoint: TelegramEndpoint, rsaPublicKey: RSAPublicKey, app: TelegramApp, layer: Int32,
    authorization: TelegramAuthorization, sessionStore: (any TelegramSessionStore)?,
    sessionScope: String?, locateDC: TelegramDatacenterLocating?,
    onMigration: (@Sendable (Int32) async throws -> Void)?,
    onPushedUpdates: (@Sendable (TL.UpdatesType) -> Void)?,
    migrations: Int, timeouts: TelegramConnectionTimeouts, log: TelegramLog
  ) async throws -> TelegramConnection {
    do {
      return try await establish(
        endpoint: endpoint, rsaPublicKey: rsaPublicKey, app: app, layer: layer,
        authorization: authorization, sessionStore: sessionStore,
        sessionScope: sessionScope, onPushedUpdates: onPushedUpdates,
        timeouts: timeouts, log: log)
    } catch {
      // Either an `rpc_error` naming a datacenter, or a login that named one
      // itself (`auth.loginTokenMigrateTo`). Both mean the same thing here.
      let redirect: Int32? =
        if case .migrate(let dcID)? = MTProtoDirective(error) {
          dcID
        } else if let migration = error as? TelegramLoginMigration {
          migration.dcID
        } else {
          nil
        }
      guard let dcID = redirect, dcID != endpoint.dcID,
        authorization.followsMigration, let locateDC
      else { throw error }
      guard migrations < maximumMigrations else {
        throw TelegramClientError.tooManyMigrations(dcID)
      }
      log.info("DC \(endpoint.dcID) homes this account on DC \(dcID); migrating")
      guard let target = try await locateDC(dcID), !target.endpoints.isEmpty else {
        throw TelegramClientError.datacenterNotAdvertised(dcID)
      }
      try await onMigration?(dcID)
      var failure: any Error = TelegramClientError.datacenterNotAdvertised(dcID)
      for candidate in target.endpoints {
        do {
          return try await connect(
            endpoint: candidate, rsaPublicKey: target.rsaPublicKey, app: app, layer: layer,
            authorization: authorization, sessionStore: sessionStore,
            sessionScope: sessionScope, locateDC: locateDC, onMigration: onMigration,
            onPushedUpdates: onPushedUpdates, migrations: migrations + 1,
            timeouts: timeouts, log: log)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          if MTProtoDirective(error)?.wait != nil { throw error }
          failure = error
          log.warning("DC \(dcID) at \(candidate.host):\(candidate.port) failed: \(error)")
        }
      }
      throw failure
    }
  }

  private static func establish(
    endpoint: TelegramEndpoint, rsaPublicKey: RSAPublicKey, app: TelegramApp, layer: Int32,
    authorization: TelegramAuthorization, sessionStore: (any TelegramSessionStore)?,
    sessionScope: String?, onPushedUpdates: (@Sendable (TL.UpdatesType) -> Void)?,
    timeouts: TelegramConnectionTimeouts, log: TelegramLog
  ) async throws -> TelegramConnection {
    let sessionKey = sessionScope.map { Self.sessionKey(scope: $0, dcID: endpoint.dcID) }
    let cached: CachedTelegramSession? =
      if let sessionStore, let sessionKey {
        try await sessionStore.session(for: sessionKey)
      } else {
        nil
      }
    // A mismatched credential is a scope/configuration error, not proof that
    // the stored key is invalid. Leave it intact for its original account.
    if let stored = cached, case .botToken(let token) = authorization,
      let tokenAccountID = TelegramBotToken.accountID(of: token),
      stored.accountID != tokenAccountID
    {
      throw TelegramClientError.sessionBelongsToAnotherAccount
    }
    if cached == nil, case .storedSessionOnly = authorization {
      throw TelegramClientError.noStoredSession
    }

    var attempt = 0
    while true {
      try Task.checkCancellation()
      attempt += 1
      let captured = Mutex<MTProtoSessionKeys?>(nil)
      let configuration = MTProtoClientConfiguration(
        rsaPublicKey: rsaPublicKey, dcID: endpoint.dcID,
        resumeSession: cached?.session,
        requestTimeout: timeouts.request, connectTimeout: timeouts.connect,
        onSessionEstablished: { keys in captured.withLock { $0 = keys } },
        onUnhandledMessage: Self.pushSink(onPushedUpdates, log: log),
        log: log.lineSink(at: .debug))
      let client = MTProtoClient(
        host: endpoint.host, port: endpoint.port, configuration: configuration)
      let transport = TelegramTransport(client: client, app: app, layer: layer)
      let api = TLClient(transport: transport)
      var phase = "connect"
      do {
        try await client.connect()
        if let cached {
          phase = "identify"
          // This authenticated RPC proves liveness as well as identity. An
          // extra ping adds no authorization evidence and delays the first RPC.
          try await proveResumedSession(
            api, is: cached.accountID, authorization: authorization, on: endpoint.dcID)
        }
      } catch {
        try? await client.disconnect()
        guard cached != nil else { throw error }
        log.warning(
          "cached session \(sessionKey ?? "") resume \(phase) failed "
            + "(attempt \(attempt)/3): \(error)")
        try Task.checkCancellation()
        if let sessionStore, let sessionKey,
          try await discardInvalidCachedSession(
            error, store: sessionStore, key: sessionKey, log: log)
        {
          return try await establish(
            endpoint: endpoint, rsaPublicKey: rsaPublicKey, app: app, layer: layer,
            authorization: authorization, sessionStore: sessionStore,
            sessionScope: sessionScope, onPushedUpdates: onPushedUpdates,
            timeouts: timeouts, log: log)
        }
        guard attempt < 3, retriesResume(error, duringConnect: phase == "connect") else {
          throw error
        }
        // The same snapshot is used for every dial; no failed probe can spend
        // a login or replace the file. Each dial has a fresh transport/session ID.
        try await Task.sleep(for: .milliseconds(250 * attempt))
        continue
      }
      do {
        let accountID: Int64
        if let cached {
          accountID = cached.accountID
        } else {
          accountID = try await authorize(
            api, app: app, using: authorization, binding: await client.sessionBinding())
          if let keys = captured.withLock({ $0 }), let sessionStore, let sessionKey {
            try await sessionStore.save(
              MTProtoStoredSession(
                authKey: keys.authKey, serverSalt: keys.serverSalt,
                expiresAt: keys.expiresAt),
              accountID: accountID, for: sessionKey)
          }
        }
        return TelegramConnection(
          endpoint: endpoint, client: client, transport: transport,
          accountID: accountID, resumedSession: cached != nil)
      } catch {
        try? await client.disconnect()
        throw error
      }
    }
  }

  /// Everything the server pushes outside an RPC reaches the client as a raw
  /// body; only an `Updates` container matters to a caller watching for changes.
  private static func pushSink(
    _ sink: (@Sendable (TL.UpdatesType) -> Void)?, log: TelegramLog
  ) -> (@Sendable (Data) -> Void)? {
    guard let sink else { return nil }
    // A push is a prompt, never the only copy: the update it carries is in the
    // difference too, and the poll interval reaches it. Dropping one therefore
    // costs promptness and nothing else — which is why this is the one place an
    // unreadable body needs no recovery at all, and why it stays at `debug`:
    // every service message the transport does not consume arrives here too.
    return { body in
      guard let updates = try? TL.UpdatesType(tlData: body) else {
        log.debug("dropping an unreadable pushed message of \(body.count) byte(s)")
        return
      }
      sink(updates)
    }
  }

  public func disconnect() async { try? await client.disconnect() }

  /// Mints an authorization another connection imports to authorize on `dcID`.
  /// Single use: the import that consumes it spends it, so a retried dial
  /// exports again.
  public func exportedAuthorization(for dcID: Int32) async throws
    -> TL.Auth.ExportedAuthorization
  {
    try await api.invoke(TL.Auth.ExportAuthorization(dcId: dcID))
  }

  /// Fetches the service's current datacenter list over an unauthorized seed
  /// session. The config's expiry is the cache deadline.
  public static func getDcList(
    seed: TelegramEndpoint, rsaPublicKey: RSAPublicKey, app: TelegramApp, layer: Int32,
    timeouts: TelegramConnectionTimeouts = .default, log: TelegramLog = .silent
  ) async throws -> FetchedDatacenterList {
    let client = MTProtoClient(
      host: seed.host, port: seed.port,
      configuration: MTProtoClientConfiguration(
        rsaPublicKey: rsaPublicKey, dcID: seed.dcID,
        requestTimeout: timeouts.request, connectTimeout: timeouts.connect,
        log: log.lineSink(at: .debug)))
    let api = TLClient(
      transport: TelegramTransport(client: client, app: app, layer: layer))
    try await client.connect()
    let config: TL.Config
    do {
      config = try await api.invoke(TL.Help.GetConfig())
    } catch {
      try? await client.disconnect()
      throw error
    }
    try? await client.disconnect()

    let datacenters = Set(config.dcOptions.map(\.id)).sorted().compactMap { dcID in
      let endpoints = telegramEndpoints(in: config.dcOptions, forDC: dcID)
      return endpoints.isEmpty
        ? nil
        : TelegramDatacenter(id: dcID, endpoints: endpoints, rsaPublicKey: rsaPublicKey)
    }
    return FetchedDatacenterList(
      datacenters: datacenters,
      expiresAt: Date(timeIntervalSince1970: TimeInterval(config.expires)))
  }

  private static func authorize(
    _ api: TLClient, app: TelegramApp, using mode: TelegramAuthorization,
    binding: MTProtoSessionBinding?
  ) async throws -> Int64 {
    switch mode {
    case .botToken(let token):
      let authorization = try await api.invoke(
        TL.Auth.ImportBotAuthorization(
          flags: 0, apiId: app.apiID, apiHash: app.apiHash, botAuthToken: token))
      guard case .authorization(let value) = authorization,
        case .user(let user) = value.user, user.bot
      else { throw TelegramClientError.unexpectedAccountKind }
      return user.id
    case .exported(let export):
      let exported = try await export()
      let authorization = try await api.invoke(
        TL.Auth.ImportAuthorization(id: exported.id, bytes: exported.bytes))
      guard case .authorization(let value) = authorization,
        case .user(let user) = value.user
      else { throw TelegramClientError.unexpectedAccountKind }
      return user.id
    case .user(let login):
      let user: TL.User
      if let bound = login as? any TelegramBoundUserLogin {
        guard let binding else { throw TelegramClientError.missingSessionBinding }
        user = try await bound.signIn(on: api, app: app, binding: binding)
      } else {
        user = try await login.signIn(on: api, app: app)
      }
      guard !user.bot else { throw TelegramClientError.unexpectedAccountKind }
      return user.id
    case .storedSessionOnly:
      // Unreachable: `establish` fails before authorizing when the cache is
      // empty, and never reaches here when it is not.
      throw TelegramClientError.noStoredSession
    }
  }

  /// Proves a resumed session is still this account's, in the terms the
  /// datacenter it was resumed on will answer.
  ///
  /// The account's own datacenter is asked who it is, and a different account
  /// means the key is not the one the credential belongs to. **A media
  /// datacenter cannot be asked**: it serves file RPCs and redirects every
  /// account query to the datacenter that homes the account, so `users.getUsers`
  /// there answers `USER_MIGRATE_<home>` — exactly what it answers a fresh
  /// login. That redirect is the proof rather than a failure: a key the
  /// datacenter does not know is answered `AUTH_KEY_UNREGISTERED` by the same
  /// call. Silence does not prove anything about authorization; it leaves the
  /// stored session intact for another attempt.
  ///
  /// Reading the redirect as a failure instead is what makes every media
  /// connection whose session was resumed — that is, every one after the first
  /// restart — fail to open, and with it every transfer of a file the account's
  /// own datacenter does not hold.
  private static func proveResumedSession(
    _ api: TLClient, is accountID: Int64, authorization: TelegramAuthorization, on dcID: Int32
  ) async throws {
    do {
      guard try await identifySelf(api) == accountID else {
        throw TelegramClientError.sessionBelongsToAnotherAccount
      }
    } catch {
      guard case .exported = authorization,
        case .migrate(let home)? = MTProtoDirective(error), home != dcID
      else { throw error }
    }
  }

  private static func identifySelf(_ api: TLClient) async throws -> Int64 {
    let users = try await api.invoke(
      TL.Users.GetUsers(id: [.inputUserSelf(TL.InputUserSelf())]))
    guard case .user(let user) = users.first else {
      throw TelegramClientError.unexpectedAccountKind
    }
    return user.id
  }

  /// Keep the persistence decision shared by every resume phase.
  static func discardInvalidCachedSession(
    _ error: any Error, store: any TelegramSessionStore, key: String, log: TelegramLog
  ) async throws -> Bool {
    guard invalidatesCachedSession(error) else { return false }
    log.warning("server rejected the cached \(key) key; discarding it")
    try await store.deleteSession(for: key)
    return true
  }

  /// Only an explicit server rejection proves that the cached authorization
  /// cannot be reused. Timeouts, transport failures and unrelated RPC errors
  /// leave it intact. See https://core.telegram.org/api/errors and
  /// https://core.telegram.org/mtproto/mtproto-transports#transport-errors.
  private static func invalidatesCachedSession(_ error: any Error) -> Bool {
    if let client = error as? MTProtoClientError {
      return client == .protocolError(-404)
    }
    guard let rpc = error as? MTProtoRPCError else { return false }
    return [
      "AUTH_KEY_UNREGISTERED", "AUTH_KEY_INVALID", "AUTH_KEY_DUPLICATED",
      "SESSION_REVOKED", "SESSION_EXPIRED",
    ].contains(rpc.message)
  }

  private static func retriesResume(_ error: any Error, duringConnect: Bool) -> Bool {
    if error is CancellationError { return false }
    if let client = error as? MTProtoClientError {
      switch client {
      case .timeout, .connectionClosed, .notConnected: return true
      default: return false
      }
    }
    if error is MTProtoRPCError { return false }
    // Socket/DNS/connect errors come from NIO before an MTProto session exists.
    // Decoding and identity errors during the proof are not transport failures.
    return duringConnect
  }
}

/// Reading a bot token without spending it.
public enum TelegramBotToken {
  /// The bot id the token names. Known before any connection is made, so a log
  /// can say which bot it is about to be, and a cached session can be checked
  /// against it, without spending the token.
  public static func accountID(of token: String) -> Int64? {
    guard let separator = token.firstIndex(of: ":"),
      let id = Int64(token[..<separator]), id > 0
    else { return nil }
    return id
  }
}
