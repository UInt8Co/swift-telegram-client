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

    var failure: any Error = DatacenterListError.empty(sessionScope)
    for seed in service.seeds {
      do {
        return try await connect(
          endpoint: seed, rsaPublicKey: service.rsaPublicKey, app: app,
          layer: service.layer, authorization: authorization,
          sessionStore: sessionStore, sessionScope: sessionScope, locateDC: locateDC,
          onPushedUpdates: onPushedUpdates, timeouts: timeouts, log: log)
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
