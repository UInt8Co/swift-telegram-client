import MTProtoClientKit
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension TelegramConnection {
  /// Connects to a service and authorizes, starting from its seed addresses and
  /// switching to the datacenter list it advertises.
  ///
  /// This is the entry point that needs no addresses: ``TelegramService/production``
  /// carries Telegram's own, and everything after the first `help.getConfig` uses
  /// what Telegram itself published. A caller that already knows where to dial —
  /// a private deployment, or a test server — passes its own ``TelegramService``
  /// instead, and nothing else changes.
  ///
  /// Seeds are tried in order and the first that answers wins; a seed that is
  /// blocked or down therefore costs one connect budget rather than the attempt.
  /// A `*_MIGRATE_X` is followed using the advertised list, which is cached in
  /// `sessionStore` until the service says it has expired.
  public static func connect(
    to service: TelegramService = .production, app: TelegramApp,
    authorization: TelegramAuthorization,
    sessionStore: any TelegramSessionStore = InMemoryTelegramSessionStore(),
    sessionScope: String = "telegram",
    onPushedUpdates: (@Sendable (TL.UpdatesType) -> Void)? = nil,
    receivedPeers: ReceivedPeerObservation? = nil,
    timeouts: TelegramConnectionTimeouts = .default,
    log: TelegramLog = .silent
  ) async throws -> TelegramConnection {
    let datacenters = TelegramDatacenterListCache(store: sessionStore, log: log)
    let locateDC: TelegramDatacenterLocating = { dcID in
      try await datacenters.getDcList(
        for: sessionScope, defaultRSAKey: service.rsaPublicKey,
        fetch: { try await list(of: service, app: app, timeouts: timeouts, log: log) }
      )
      .first { $0.id == dcID }?.target
    }

    // The scope also holds sessions on datacenters its media connections
    // imported authorizations to; resuming one of those only earns a redirect
    // home. Dial the home last connected to first. An unreadable hint is no
    // hint: it costs at most that one redirect.
    let home = try? await sessionStore.homeDatacenter(for: sessionScope)
    var failure: any Error = DatacenterListError.empty(sessionScope)
    for seed in seeds(of: service, homeFirst: home) {
      do {
        let connection = try await connect(
          endpoint: seed, rsaPublicKey: service.rsaPublicKey, app: app,
          layer: service.layer, authorization: authorization,
          sessionStore: sessionStore, sessionScope: sessionScope, locateDC: locateDC,
          onPushedUpdates: onPushedUpdates, receivedPeers: receivedPeers,
          timeouts: timeouts, log: log)
        // An exported login may rest on a datacenter that is not its home.
        let exported = if case .exported = authorization { true } else { false }
        if !exported, connection.endpoint.dcID != home {
          do {
            try await sessionStore.saveHomeDatacenter(connection.endpoint.dcID, for: sessionScope)
          } catch {
            log.warning("could not remember DC \(connection.endpoint.dcID) as home: \(error)")
          }
        }
        return connection
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A wait is the service talking, not the address failing: trying the
        // next seed would spend the same budget again and lengthen the wait.
        if MTProtoDirective(error)?.wait != nil { throw error }
        failure = error
        log.warning("seed \(seed.host):\(seed.port) failed: \(error)")
      }
    }
    throw failure
  }

  /// The service's seeds with `home`'s moved to the front, otherwise in order.
  static func seeds(of service: TelegramService, homeFirst home: Int32?) -> [TelegramEndpoint] {
    guard let home else { return service.seeds }
    return service.seeds.filter { $0.dcID == home } + service.seeds.filter { $0.dcID != home }
  }

  /// The service's datacenter list, asked of whichever seed answers first.
  public static func list(
    of service: TelegramService, app: TelegramApp,
    timeouts: TelegramConnectionTimeouts = .default, log: TelegramLog = .silent
  ) async throws -> FetchedDatacenterList {
    var failure: any Error = DatacenterListError.empty("seed")
    for seed in service.seeds {
      do {
        return try await getDcList(
          seed: seed, rsaPublicKey: service.rsaPublicKey, app: app, layer: service.layer,
          timeouts: timeouts, log: log)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if MTProtoDirective(error)?.wait != nil { throw error }
        failure = error
        log.warning("seed \(seed.host):\(seed.port) failed: \(error)")
      }
    }
    throw failure
  }
}
