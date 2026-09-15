import MTProtoClientKit
import TelegramSchema

/// The connections one account holds open: its own, plus one per datacenter
/// that holds something its own datacenter does not.
///
/// A file lives on the datacenter that stored it, which is rarely the one that
/// homes the account — so `upload.getFile` answers `FILE_MIGRATE_X` and the read
/// has to happen on DC X. The original credential cannot open that connection:
/// it authorizes only on the home DC, and DC X answers a fresh login with
/// `USER_MIGRATE_<home>`. Following that redirect is what makes a pool hand out
/// a *home*-DC connection under the key of the DC that holds the file, so every
/// read of it answers `FILE_MIGRATE_X` again and the transfer fails as a loop. A
/// foreign datacenter is therefore authorized the only way it can be: the home
/// connection exports an authorization for it and the new connection imports it.
public actor TelegramClientPool {
  private let main: TelegramConnection
  private let app: TelegramApp
  private let targets: [Int32: TelegramDatacenterTarget]
  private let sessionStore: any TelegramSessionStore
  /// The session-cache scope these connections are filed under, and how the log
  /// names them. A cached session belongs to one account on one datacenter of
  /// one service; sharing a scope between two services would resume the wrong
  /// one.
  private let sessionScope: String
  private let log: TelegramLog
  private var clients: [Int32: Task<TelegramConnection, Error>]

  /// `rsaPublicKey` is the trust anchor of the datacenter `main` is connected
  /// to, when the caller knows it: it names an address the pool never dials
  /// again — the live connection is already filed under that datacenter — and
  /// may be left out when the datacenter list already carries it.
  public init(
    main: TelegramConnection, app: TelegramApp, rsaPublicKey: RSAPublicKey? = nil,
    datacenters: [TelegramDatacenter], sessionStore: any TelegramSessionStore,
    sessionScope: String = "telegram", log: TelegramLog = .silent
  ) {
    self.log = log
    self.main = main
    self.app = app
    self.sessionStore = sessionStore
    self.sessionScope = sessionScope
    // Every address a datacenter advertises, in preference order: the first one
    // can be down, and a media connection needs a fallback like any other. Each
    // is dialled with its own datacenter's trust anchor; the account's own is
    // the address and key that already handshook.
    var targets: [Int32: TelegramDatacenterTarget] = [:]
    for dc in datacenters where !dc.endpoints.isEmpty { targets[dc.id] = dc.target }
    if let rsaPublicKey {
      targets[main.endpoint.dcID] = TelegramDatacenterTarget(
        endpoints: [main.endpoint], rsaPublicKey: rsaPublicKey)
    }
    self.targets = targets
    self.clients = [main.endpoint.dcID: Task { main }]
  }

  public func connection(for dcID: Int32) async throws -> TelegramConnection {
    if let task = clients[dcID] { return try await task.value }
    guard let target = targets[dcID], !target.endpoints.isEmpty else {
      throw TelegramClientError.datacenterNotAdvertised(dcID)
    }
    log.info("opening a \(sessionScope) connection to DC \(dcID)")
    let app = self.app
    let sessionStore = self.sessionStore
    let sessionScope = self.sessionScope
    let main = self.main
    let log = self.log
    let task = Task {
      var failure: any Error = TelegramClientError.datacenterNotAdvertised(dcID)
      for candidate in target.endpoints {
        do {
          // No `locateDC`: this connection is for the datacenter that holds the
          // object, and there is nowhere else to be sent. A redirect from here
          // is a failure the caller sees.
          return try await TelegramConnection.connect(
            endpoint: candidate, rsaPublicKey: target.rsaPublicKey, app: app,
            layer: main.layer,
            authorization: .exported { try await main.exportedAuthorization(for: dcID) },
            sessionStore: sessionStore, sessionScope: sessionScope, log: log)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          if MTProtoDirective(error)?.wait != nil { throw error }
          failure = error
          log.warning(
            "\(sessionScope) DC \(dcID) at \(candidate.host):\(candidate.port) failed: "
              + "\(error)")
        }
      }
      throw failure
    }
    clients[dcID] = task
    do {
      return try await task.value
    } catch {
      clients.removeValue(forKey: dcID)
      throw error
    }
  }

  public func shutdown() async {
    let clients = self.clients.values
    self.clients.removeAll()
    for task in clients {
      if let connection = try? await task.value { await connection.disconnect() }
    }
  }
}
