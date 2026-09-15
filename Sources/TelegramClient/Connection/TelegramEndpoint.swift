import MTProtoClientKit
import TelegramSchema

/// One address a datacenter answers on.
public struct TelegramEndpoint: Codable, Equatable, Hashable, Sendable {
  public var dcID: Int32
  public var host: String
  public var port: Int

  public init(dcID: Int32, host: String, port: Int) {
    self.dcID = dcID
    self.host = host
    self.port = port
  }
}

/// Where a `*_MIGRATE_X` error points: every address that datacenter answers on
/// plus the trust anchor for it, which need not be the same key for every
/// datacenter.
public struct TelegramDatacenterTarget: Sendable {
  public var endpoints: [TelegramEndpoint]
  public var rsaPublicKey: RSAPublicKey

  public init(endpoints: [TelegramEndpoint], rsaPublicKey: RSAPublicKey) {
    self.endpoints = endpoints
    self.rsaPublicKey = rsaPublicKey
  }
}

/// Resolves a migration target. `nil` means the service never advertised that
/// datacenter, which is a failure to report rather than an address to follow.
public typealias TelegramDatacenterLocating =
  @Sendable (Int32) async throws -> TelegramDatacenterTarget?

/// The addresses a `help.getConfig` advertises for one datacenter that this
/// client can actually finish a handshake with, in the order it advertised
/// them. `static` duplicates one already listed, so the set dedupes.
///
/// Everything excluded here accepts the TCP connection and then goes quiet,
/// which costs a whole connect budget to discover: a `media_only` frontend
/// abandons the handshake (it is a file-serving address, not a second address
/// for the datacenter — the general one serves file RPCs too), a `tcpo_only`
/// one speaks only the obfuscated transport this client does not implement, and
/// a `cdn` one or one carrying an MTProxy `secret` is not the datacenter at all.
public func telegramEndpoints(
  in options: [TL.DcOption], forDC dcID: Int32
) -> [TelegramEndpoint] {
  var seen: Set<TelegramEndpoint> = []
  return
    options
    .filter {
      $0.id == dcID && !$0.ipv6 && !$0.mediaOnly && !$0.tcpoOnly && !$0.cdn
        && $0.secret == nil
    }
    .map { TelegramEndpoint(dcID: dcID, host: $0.ipAddress, port: Int($0.port)) }
    .filter { seen.insert($0).inserted }
}
