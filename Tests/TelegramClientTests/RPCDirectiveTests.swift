import MTProtoClientKit
import TelegramSchema
import Synchronization
import Testing

@testable import TelegramClient

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct RPCDirectiveTests {
  @Test func readsMigrationAndFloodWaitInstructions() {
    #expect(
      MTProtoDirective(MTProtoRPCError(code: 303, message: "USER_MIGRATE_5"))
        == .migrate(dcID: 5))
    #expect(
      MTProtoDirective(MTProtoRPCError(code: 303, message: "FILE_MIGRATE_2"))
        == .migrate(dcID: 2))
    #expect(
      MTProtoDirective(MTProtoRPCError(code: 420, message: "FLOOD_WAIT_30"))
        == .floodWait(seconds: 30))
    #expect(
      MTProtoDirective(MTProtoRPCError(code: 420, message: "FLOOD_PREMIUM_WAIT_7"))
        == .floodWait(seconds: 7))
    #expect(MTProtoDirective(MTProtoRPCError(code: 400, message: "CHANNEL_INVALID")) == nil)
    #expect(MTProtoDirective(MTProtoRPCError(code: 303, message: "USER_MIGRATE_x")) == nil)
    #expect(MTProtoDirective(MTProtoClientError.connectionClosed) == nil)
  }

  @Test func floodWaitAddsASecondOfMargin() {
    #expect(MTProtoDirective.floodWait(seconds: 4).wait == .seconds(5))
    #expect(MTProtoDirective.migrate(dcID: 4).wait == nil)
  }

  @Test func honoringFloodWaitRetriesOnceAndRethrowsOtherErrors() async throws {
    let attempts = Mutex(0)
    let value = try await FloodWait.honoring("test") {
      let attempt = attempts.withLock { count -> Int in
        count += 1
        return count
      }
      if attempt == 1 { throw MTProtoRPCError(code: 420, message: "FLOOD_WAIT_0") }
      return attempt
    }
    #expect(value == 2)

    await #expect(throws: MTProtoRPCError(code: 400, message: "CHANNEL_INVALID")) {
      try await FloodWait.honoring("test") {
        throw MTProtoRPCError(code: 400, message: "CHANNEL_INVALID")
      }
    }
  }

  /// Every address excluded here answers a dial with silence rather than an
  /// error, so keeping one costs a whole connect budget to rule out.
  @Test func keepsOnlyTheAddressesADialCanFinishAHandshakeWith() {
    let options: [TL.DcOption] = [
      TL.DcOption(id: 2, ipAddress: "seed", port: 443),
      TL.DcOption(mediaOnly: true, id: 5, ipAddress: "media", port: 443),
      TL.DcOption(id: 5, ipAddress: "general", port: 443),
      TL.DcOption(static: true, id: 5, ipAddress: "general", port: 443),
      TL.DcOption(id: 5, ipAddress: "second", port: 443),
      TL.DcOption(tcpoOnly: true, id: 5, ipAddress: "obfuscated", port: 443),
      TL.DcOption(ipv6: true, id: 5, ipAddress: "::1", port: 443),
      TL.DcOption(cdn: true, id: 5, ipAddress: "cdn", port: 443),
      TL.DcOption(id: 5, ipAddress: "mtproxy", port: 443, secret: Data([1])),
    ]
    #expect(
      telegramEndpoints(in: options, forDC: 5) == [
        TelegramEndpoint(dcID: 5, host: "general", port: 443),
        TelegramEndpoint(dcID: 5, host: "second", port: 443),
      ])
    #expect(telegramEndpoints(in: options, forDC: 4).isEmpty)
  }

  @Test func sessionKeysAreScopedPerDatacenter() {
    #expect(TelegramConnection.sessionKey(scope: "telegram", dcID: 5) == "telegram:5")
    #expect(TelegramConnection.sessionKey(scope: "media", dcID: 1) == "media:1")
  }
}
