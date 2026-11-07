#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import TelegramSchema
import TelegramBot

@Suite struct EphemeralRepliesTests {

  @Test func separateNamespace() throws {
    let reply = EphemeralReplies.message(12)
    #expect(reply == .inputReplyToEphemeralMessage(.init(id: 12)))
    #expect(try TL.InputReplyToType(tlData: reply.tlSerialized()) == reply)
  }
}
