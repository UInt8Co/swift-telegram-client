#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import MTProtoClientKit
import TelegramSchema
import TelegramClient

@Suite struct MessageContentRejectionTests {
  @Test func richContentRejectionHasNarrowScope() {
    for name in ["RICH_MESSAGE_RICH_TEXT_INVALID", "RICH_MESSAGE_RICH_TEXT_UNSUPPORTED", "RICH_MESSAGE_DEPTH_INVALID"] {
      #expect(MessageContentRejection.richMessage(MTProtoRPCError(code: 400, message: name)))
    }
    let otherErrors: [any Error] = [
      MTProtoRPCError(code: 500, message: "RICH_MESSAGE_RICH_TEXT_INVALID"),
      MTProtoRPCError(code: 403, message: "CHAT_WRITE_FORBIDDEN"),
      MTProtoRPCError(code: 420, message: "FLOOD_WAIT_30"),
      MTProtoRPCError(code: 400, message: "RICH_MESSAGE_UNEXPECTED_FUTURE_ERROR"),
      MTProtoRPCError(code: 400, message: "RICH_MESSAGE_CONTENT_REQUIRED"),
      MTProtoClientError.timeout, MTProtoClientError.connectionClosed, CancellationError(),
    ]
    for error in otherErrors { #expect(!MessageContentRejection.richMessage(error)) }
  }

  @Test func protectedForwardAndMediaRefusals() {
    for code: Int32 in [400, 403, 406] {
      #expect(MessageContentRejection.protectedForward(MTProtoRPCError(code: code, message: "CHAT_FORWARDS_RESTRICTED")))
      #expect(MessageContentRejection.mediaOrEntities(MTProtoRPCError(code: code, message: "FILE_REFERENCE_EXPIRED")))
    }
    #expect(!MessageContentRejection.protectedForward(MTProtoRPCError(code: 500, message: "CHAT_FORWARDS_RESTRICTED")))
    #expect(!MessageContentRejection.mediaOrEntities(MTProtoRPCError(code: 420, message: "FLOOD_WAIT_1")))
    #expect(!MessageContentRejection.mediaOrEntities(CancellationError()))
  }
}
