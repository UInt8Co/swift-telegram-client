import Testing

@testable import TelegramClient
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The built-in bootstrap sets, and the shapes a caller names a peer with.
@Suite struct TelegramServiceTests {
  @Test("production and test seeds are distinct networks with distinct keys")
  func builtInServices() {
    let production = TelegramService.production
    let test = TelegramService.test

    #expect(!production.seeds.isEmpty)
    #expect(!test.seeds.isEmpty)
    #expect(
      production.rsaPublicKey.fingerprint != test.rsaPublicKey.fingerprint,
      "the handshake matches on fingerprint, so a swapped key must fail early")
    #expect(
      Set(production.seeds.map(\.host)).isDisjoint(with: Set(test.seeds.map(\.host))))
    #expect(production.layer == TelegramSchemaLayer.current)
  }

  @Test("every seed is offered on each of Telegram's ports, in its order")
  func seedsCoverEveryPort() {
    let seeds = TelegramService.production.seeds

    for host in Set(seeds.map(\.host)) {
      let ports = seeds.filter { $0.host == host }.map(\.port)
      #expect(
        ports == TelegramService.ports,
        "a network that only lets 80 or 5222 out still needs a way through")
    }
    // The first seed is the one a healthy network uses, so it has to be a
    // datacenter address on 443 rather than a fallback port.
    #expect(seeds.first?.port == 443)
  }

  @Test("a caller can point the client at its own service")
  func customService() throws {
    let key = TelegramService.production.rsaPublicKey
    let custom = TelegramService(
      seeds: [TelegramEndpoint(dcID: 1, host: "127.0.0.1", port: 4443)],
      rsaPublicKey: key, layer: 200)

    #expect(custom.seeds.count == 1)
    #expect(custom.layer == 200, "a private deployment announces its own layer")
  }

  @Test("a QR login token becomes the URL a scanning client expects")
  func qrLoginURL() {
    // Bytes chosen so the plain base64 uses both `+` and `/` and needs padding:
    // all three are exactly what the URL form has to change.
    let token = Data([0xfb, 0xff, 0xbf, 0x3e, 0x7d])

    let url = TelegramQRLogin.loginURL(token: token)

    #expect(token.base64EncodedString() == "+/+/Pn0=")
    #expect(url == "tg://login?token=-_-_Pn0")
  }

  @Test("a peer locator accepts every form a channel is written in")
  func peerLocators() {
    #expect(PeerLocator("@Durov") == .username("durov"))
    #expect(PeerLocator("1234567890") == .id(1_234_567_890))
    #expect(PeerLocator("-1001234567890") == .id(1_234_567_890), "the Bot API form")
    #expect(PeerLocator("@") == nil)
    #expect(PeerLocator("@not a username") == nil)
    #expect(PeerLocator("0") == nil)
    #expect(PeerLocator("-1") == nil)
  }
}
