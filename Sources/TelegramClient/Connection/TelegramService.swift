import MTProtoClientKit
import TelegramSchema

/// Which service to talk to: where to start, whose key to trust, and which API
/// layer to announce.
///
/// ``production`` and ``test`` are Telegram's own, so an application that only
/// wants Telegram never has to name an address. Anything MTProto-shaped is
/// reachable by building one of these instead — a private deployment of the
/// protocol, or a local server under test — which is the only thing in this
/// package that is specific to *whose* API it is.
///
/// The seeds are a starting point, not the datacenter list: the first thing a
/// client does with one is `help.getConfig`, and the addresses that comes back
/// with are what it uses from then on (``TelegramDatacenterListCache``).
public struct TelegramService: Sendable {
  /// Addresses to try, in order, before any datacenter list is known.
  public var seeds: [TelegramEndpoint]
  /// The trust anchor the auth-key handshake matches on. A service that
  /// publishes one key per datacenter supplies them through the datacenter list
  /// instead, and this is the one the seed dial uses.
  public var rsaPublicKey: RSAPublicKey
  /// The API layer to announce, which is also the layer replies and pushes
  /// arrive in.
  public var layer: Int32

  public init(seeds: [TelegramEndpoint], rsaPublicKey: RSAPublicKey, layer: Int32) {
    self.seeds = seeds
    self.rsaPublicKey = rsaPublicKey
    self.layer = layer
  }

  /// Telegram's production datacenters.
  ///
  /// The addresses and the key are the ones Telegram's own client ships as its
  /// bootstrap set; ports are tried in the order it tries them. IPv6 addresses
  /// are left out because this transport does not dial them.
  public static let production = TelegramService(
    seeds: endpoints([
      (2, "149.154.167.51"),
      (2, "95.161.76.100"),
      (1, "149.154.175.50"),
      (3, "149.154.175.100"),
      (4, "149.154.167.91"),
      (5, "149.154.171.5"),
    ]),
    rsaPublicKey: key(
      """
      -----BEGIN RSA PUBLIC KEY-----
      MIIBCgKCAQEA6LszBcC1LGzyr992NzE0ieY+BSaOW622Aa9Bd4ZHLl+TuFQ4lo4g
      5nKaMBwK/BIb9xUfg0Q29/2mgIR6Zr9krM7HjuIcCzFvDtr+L0GQjae9H0pRB2OO
      62cECs5HKhT5DZ98K33vmWiLowc621dQuwKWSQKjWf50XYFw42h21P2KXUGyp2y/
      +aEyZ+uVgLLQbRA1dEjSDZ2iGRy12Mk5gpYc397aYp438fsJoHIgJ2lgMv5h7WY9
      t6N/byY9Nw9p21Og3AoXSL2q/2IJ1WRUhebgAdGVMlV1fkuOQoEzR7EdpqtQD9Cs
      5+bfo3Nhmcyvk5ftB0WkJ9z6bNZ7yxrP8wIDAQAB
      -----END RSA PUBLIC KEY-----
      """),
    layer: TelegramSchemaLayer.current)

  /// Telegram's test datacenters, which issue test accounts and hold no real
  /// data. A different key: the handshake matches on fingerprint, so pointing a
  /// production key at these fails at the handshake rather than later.
  public static let test = TelegramService(
    seeds: endpoints([
      (2, "149.154.167.40"),
      (1, "149.154.175.10"),
      (3, "149.154.175.117"),
    ]),
    rsaPublicKey: key(
      """
      -----BEGIN RSA PUBLIC KEY-----
      MIIBCgKCAQEAyMEdY1aR+sCR3ZSJrtztKTKqigvO/vBfqACJLZtS7QMgCGXJ6XIR
      yy7mx66W0/sOFa7/1mAZtEoIokDP3ShoqF4fVNb6XeqgQfaUHd8wJpDWHcR2OFwv
      plUUI1PLTktZ9uW2WE23b+ixNwJjJGwBDJPQEQFBE+vfmH0JP503wr5INS1poWg/
      j25sIWeYPHYeOrFp/eXaqhISP6G+q2IeTaWTXpwZj4LzXq5YOpk4bYEQ6mvRq7D1
      aHWfYmlEGepfaYR8Q0YqvvhYtMte3ITnuSJs171+GDqpdKcSwHnd6FudwGO4pcCO
      j4WcDuXc2CTHgH8gFTNhp/Y8/SpDOhvn9QIDAQAB
      -----END RSA PUBLIC KEY-----
      """),
    layer: TelegramSchemaLayer.current)

  /// The ports Telegram's own client tries, in its order. A datacenter answers
  /// on all of them; the extra two are there for networks that only let 80 or
  /// 5222 out.
  static let ports = [443, 80, 5222]

  private static func endpoints(_ addresses: [(Int32, String)]) -> [TelegramEndpoint] {
    addresses.flatMap { dcID, host in
      ports.map { TelegramEndpoint(dcID: dcID, host: host, port: $0) }
    }
  }

  /// The PEMs above are compile-time constants of this package, so a parse
  /// failure is a bug in the literal rather than anything a caller can cause.
  private static func key(_ pem: String) -> RSAPublicKey {
    guard let key = RSAPublicKey(pem: pem) else {
      preconditionFailure("the built-in RSA public key does not parse")
    }
    return key
  }
}
