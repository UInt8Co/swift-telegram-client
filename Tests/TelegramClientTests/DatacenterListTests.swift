import MTProtoClientKit
import Synchronization
import Testing

@testable import TelegramClient

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// What the datacenter-list cache does about time and about failure.
///
/// The list is the only thing that makes a migration followable, so the rules
/// that matter are: do not re-fetch one that is still fresh, and do not lose one
/// that has expired while the service is unreachable — a client that refused to
/// start because `help.getConfig` timed out would turn a brief outage into a
/// total one.
@Suite struct DatacenterListTests {
  private static let key = TelegramService.production.rsaPublicKey
  private static let keyPEM = """
    -----BEGIN RSA PUBLIC KEY-----
    MIIBCgKCAQEA6LszBcC1LGzyr992NzE0ieY+BSaOW622Aa9Bd4ZHLl+TuFQ4lo4g
    5nKaMBwK/BIb9xUfg0Q29/2mgIR6Zr9krM7HjuIcCzFvDtr+L0GQjae9H0pRB2OO
    62cECs5HKhT5DZ98K33vmWiLowc621dQuwKWSQKjWf50XYFw42h21P2KXUGyp2y/
    +aEyZ+uVgLLQbRA1dEjSDZ2iGRy12Mk5gpYc397aYp438fsJoHIgJ2lgMv5h7WY9
    t6N/byY9Nw9p21Og3AoXSL2q/2IJ1WRUhebgAdGVMlV1fkuOQoEzR7EdpqtQD9Cs
    5+bfo3Nhmcyvk5ftB0WkJ9z6bNZ7yxrP8wIDAQAB
    -----END RSA PUBLIC KEY-----
    """

  @Test("a list that has not expired is served from the store, not fetched again")
  func reusesAFreshList() async throws {
    let store = InMemoryTelegramSessionStore()
    let fetched = Mutex(0)

    let first = try await TelegramDatacenterListCache(store: store).getDcList(
      for: "telegram", defaultRSAKey: Self.key, now: Date(timeIntervalSince1970: 100)
    ) {
      fetched.withLock { $0 += 1 }
      return FetchedDatacenterList(
        datacenters: [
          TelegramDatacenter(
            id: 5, endpoints: [TelegramEndpoint(dcID: 5, host: "current", port: 443)],
            rsaPublicKey: Self.key)
        ],
        expiresAt: Date(timeIntervalSince1970: 200))
    }
    #expect(first[0].endpoints[0].host == "current")

    // A second cache over the same store stands in for a restart: the list
    // outlives the object that fetched it.
    let restored = try await TelegramDatacenterListCache(store: store).getDcList(
      for: "telegram", defaultRSAKey: Self.key, now: Date(timeIntervalSince1970: 150)
    ) {
      Issue.record("a list that is still fresh must not be fetched again")
      throw TestFailure.unexpectedFetch
    }

    #expect(restored[0].endpoints[0].host == "current")
    #expect(restored[0].rsaPublicKey.fingerprint == Self.key.fingerprint)
    #expect(fetched.withLock { $0 } == 1)
  }

  @Test("a failed refresh falls back to the expired list")
  func staleFallback() async throws {
    let store = InMemoryTelegramSessionStore()
    let cache = TelegramDatacenterListCache(store: store)
    _ = try await cache.getDcList(for: "telegram", now: Date(timeIntervalSince1970: 100)) {
      FetchedDatacenterList(
        datacenters: [
          TelegramDatacenter(
            id: 2, endpoints: [TelegramEndpoint(dcID: 2, host: "cached", port: 443)],
            rsaPublicKey: Self.key, rsaPublicKeyPEM: Self.keyPEM)
        ],
        expiresAt: Date(timeIntervalSince1970: 101))
    }

    let stale = try await cache.getDcList(for: "telegram", now: Date(timeIntervalSince1970: 102)) {
      throw TestFailure.unexpectedFetch
    }

    #expect(stale[0].endpoints[0].host == "cached")
    #expect(
      stale[0].rsaPublicKey.fingerprint == Self.key.fingerprint,
      "the key travels with the list, so a restored entry needs no default")
  }

  @Test("a restored entry with no key of its own needs a default")
  func missingKeyIsRefused() async throws {
    let store = InMemoryTelegramSessionStore()
    try await store.saveDatacenterList(
      StoredDatacenterList(
        datacenters: [
          StoredDatacenterList.Datacenter(
            id: 4, name: nil,
            endpoints: [TelegramEndpoint(dcID: 4, host: "cached", port: 443)],
            rsaPublicKeyPEM: nil)
        ],
        expiresAt: Date(timeIntervalSince1970: 200)),
      for: "telegram")
    let cache = TelegramDatacenterListCache(store: store)

    await #expect(throws: DatacenterListError.missingPublicKey(4)) {
      try await cache.getDcList(for: "telegram", now: Date(timeIntervalSince1970: 100)) {
        throw TestFailure.unexpectedFetch
      }
    }
  }

  @Test("a refresh that advertises nothing is a failure, not an empty list")
  func emptyRefreshIsRefused() async throws {
    let cache = TelegramDatacenterListCache(store: InMemoryTelegramSessionStore())

    await #expect(throws: DatacenterListError.empty("telegram")) {
      try await cache.getDcList(for: "telegram", now: Date(timeIntervalSince1970: 100)) {
        FetchedDatacenterList(
          datacenters: [], expiresAt: Date(timeIntervalSince1970: 200))
      }
    }
  }

  private enum TestFailure: Error {
    case unexpectedFetch
  }
}
