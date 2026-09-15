import MTProtoClientKit

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// One datacenter as a client needs it: where to reach it, and whose key to
/// trust when handshaking with it.
public struct TelegramDatacenter: Sendable {
  public let id: Int32
  public let name: String?
  public let endpoints: [TelegramEndpoint]
  public let rsaPublicKey: RSAPublicKey

  /// The key as it was published, kept so a cached list can be restored without
  /// the caller having to supply a default. `nil` when the list carried no key
  /// of its own and the caller's default stands in.
  public let rsaPublicKeyPEM: String?

  public init(
    id: Int32, name: String? = nil, endpoints: [TelegramEndpoint],
    rsaPublicKey: RSAPublicKey, rsaPublicKeyPEM: String? = nil
  ) {
    self.id = id
    self.name = name
    self.endpoints = endpoints
    self.rsaPublicKey = rsaPublicKey
    self.rsaPublicKeyPEM = rsaPublicKeyPEM
  }

  public var target: TelegramDatacenterTarget {
    TelegramDatacenterTarget(endpoints: endpoints, rsaPublicKey: rsaPublicKey)
  }
}

/// A datacenter list together with the moment the service said it goes stale.
public struct FetchedDatacenterList: Sendable {
  public let datacenters: [TelegramDatacenter]
  public let expiresAt: Date

  public init(datacenters: [TelegramDatacenter], expiresAt: Date) {
    self.datacenters = datacenters
    self.expiresAt = expiresAt
  }
}

/// The persisted form of a datacenter list. Public because a
/// ``TelegramSessionStore`` has to be able to write it; `Codable`, so the
/// simplest store is one JSON blob per scope.
public struct StoredDatacenterList: Codable, Equatable, Sendable {
  public struct Datacenter: Codable, Equatable, Sendable {
    public var id: Int32
    public var name: String?
    public var endpoints: [TelegramEndpoint]
    public var rsaPublicKeyPEM: String?

    public init(
      id: Int32, name: String? = nil, endpoints: [TelegramEndpoint],
      rsaPublicKeyPEM: String? = nil
    ) {
      self.id = id
      self.name = name
      self.endpoints = endpoints
      self.rsaPublicKeyPEM = rsaPublicKeyPEM
    }
  }

  public var datacenters: [Datacenter]
  public var expiresAt: Date

  public init(datacenters: [Datacenter], expiresAt: Date) {
    self.datacenters = datacenters
    self.expiresAt = expiresAt
  }
}

/// The current datacenter list for one service, persisted between runs.
///
/// A stale list remains usable when the authority for it is temporarily
/// unavailable: the addresses rarely change, and refusing to start because the
/// list could not be refreshed would turn a brief outage into a total one.
public actor TelegramDatacenterListCache {
  private let store: any TelegramSessionStore
  private let log: TelegramLog

  public init(store: any TelegramSessionStore, log: TelegramLog = .silent) {
    self.store = store
    self.log = log
  }

  public func getDcList(
    for scope: String, defaultRSAKey: RSAPublicKey? = nil, now: Date = Date(),
    fetch: @Sendable () async throws -> FetchedDatacenterList
  ) async throws -> [TelegramDatacenter] {
    let stored = try await store.datacenterList(for: scope)
    if let stored, stored.expiresAt > now {
      return try Self.restore(stored, defaultRSAKey: defaultRSAKey)
    }
    do {
      let fresh = try await fetch()
      guard !fresh.datacenters.isEmpty else { throw DatacenterListError.empty(scope) }
      try await store.saveDatacenterList(Self.store(fresh), for: scope)
      return fresh.datacenters
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard let stored else { throw error }
      log.warning("\(scope) DC-list refresh failed (\(error)); using the cached list")
      return try Self.restore(stored, defaultRSAKey: defaultRSAKey)
    }
  }

  private static func store(_ list: FetchedDatacenterList) -> StoredDatacenterList {
    StoredDatacenterList(
      datacenters: list.datacenters.map {
        StoredDatacenterList.Datacenter(
          id: $0.id, name: $0.name, endpoints: $0.endpoints,
          rsaPublicKeyPEM: $0.rsaPublicKeyPEM)
      },
      expiresAt: list.expiresAt)
  }

  private static func restore(
    _ list: StoredDatacenterList, defaultRSAKey: RSAPublicKey?
  ) throws -> [TelegramDatacenter] {
    try list.datacenters.map { dc in
      let key: RSAPublicKey
      if let pem = dc.rsaPublicKeyPEM {
        guard let parsed = RSAPublicKey(pem: pem) else {
          throw DatacenterListError.invalidPublicKey(dc.id)
        }
        key = parsed
      } else if let defaultRSAKey {
        key = defaultRSAKey
      } else {
        throw DatacenterListError.missingPublicKey(dc.id)
      }
      return TelegramDatacenter(
        id: dc.id, name: dc.name, endpoints: dc.endpoints,
        rsaPublicKey: key, rsaPublicKeyPEM: dc.rsaPublicKeyPEM)
    }
  }
}

public enum DatacenterListError: Error, Equatable, Sendable, CustomStringConvertible {
  case empty(String)
  case invalidPublicKey(Int32)
  case missingPublicKey(Int32)

  public var description: String {
    switch self {
    case .empty(let scope): "\(scope) advertised no usable datacenter"
    case .invalidPublicKey(let dcID): "cached datacenter \(dcID) has an invalid RSA key"
    case .missingPublicKey(let dcID): "cached datacenter \(dcID) has no RSA key"
    }
  }
}
