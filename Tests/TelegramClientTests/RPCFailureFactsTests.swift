import MTProtoClientKit
import Testing
@testable import TelegramClient

@Suite struct RPCFailureFactsTests {
  @Test(arguments: [
    MTProtoRPCError(code: 500, message: "RPC_CALL_FAIL"),
    MTProtoRPCError(code: 500, message: "INTERNAL"),
    MTProtoRPCError(code: -500, message: "INTERNAL"),
    MTProtoRPCError(code: -503, message: "Timeout"),
    MTProtoRPCError(code: 503, message: "SERVICE_UNAVAILABLE"),
    // Telegram documents this as an earlier send still in flight. Retrying
    // the SAME ID must wait for a receipt, never manufacture one or repost.
    MTProtoRPCError(code: 500, message: "RANDOM_ID_DUPLICATE"),
  ])
  func internalErrorsAreTransient(error: MTProtoRPCError) {
    #expect(RPCServerFailure.describes(error))
  }

  @Test(arguments: [
    MTProtoRPCError(code: 400, message: "RICH_MESSAGE_CONTENT_REQUIRED"),
    MTProtoRPCError(code: 403, message: "CHAT_WRITE_FORBIDDEN"),
    MTProtoRPCError(code: 401, message: "AUTH_KEY_UNREGISTERED"),
    MTProtoRPCError(code: 420, message: "FLOOD_WAIT_60"),
    MTProtoRPCError(code: .min, message: "unknown"),
  ])
  func otherFailuresKeepTheirOwnPolicy(error: MTProtoRPCError) {
    #expect(!RPCServerFailure.describes(error))
  }

  @Test func cancellationAndUnexpectedErrorsAreNotServerFailures() {
    #expect(!RPCServerFailure.describes(CancellationError()))
    #expect(!RPCServerFailure.describes(Failure.other))
  }
  @Test func targetDeactivationDoesNotConfuseInvalidReferencesOrRevokedLogin() {
    for message in ["INPUT_USER_DEACTIVATED", "USER_DEACTIVATED"] {
      #expect(TargetUserDeactivated.describes(MTProtoRPCError(code: 400, message: message)))
      #expect(!TargetUserDeactivated.describes(MTProtoRPCError(code: 401, message: message)))
    }
    for message in ["USER_ID_INVALID", "PEER_ID_INVALID", "CHANNEL_PRIVATE", "AUTH_KEY_UNREGISTERED"] {
      #expect(!TargetUserDeactivated.describes(MTProtoRPCError(code: 400, message: message)))
    }
  }
  private enum Failure: Error { case other }
  @Test func groupAccessErrorsDistinguishAbsentGroupsFromFailedLookups() {
    let absent: [any Error] = [
      MTProtoRPCError(code: 400, message: "CHANNEL_INVALID"),
      MTProtoRPCError(code: 400, message: "CHAT_ID_INVALID"),
      MTProtoRPCError(code: 400, message: "PEER_ID_INVALID"),
      MTProtoRPCError(code: 406, message: "CHANNEL_PRIVATE"),
      MTProtoRPCError(code: 400, message: "CHANNEL_PUBLIC_GROUP_NA"),
      MTProtoRPCError(code: 400, message: "USER_NOT_PARTICIPANT"),
      TelegramClientError.peerNotFound("channel:123"),
      TelegramClientError.missingAccessHash("channel:123"),
      TelegramClientError.channelRequired("chat:123"),
    ]
    for error in absent { #expect(PeerAccessFailure.groupUnavailable(error), "\(error)") }
    let failed: [any Error] = [
      MTProtoRPCError(code: 400, message: "CHAT_ADMIN_REQUIRED"),
      MTProtoRPCError(code: 403, message: "CHAT_ADMIN_REQUIRED"),
      MTProtoRPCError(code: 400, message: "BOT_METHOD_INVALID"),
      MTProtoRPCError(code: 420, message: "FLOOD_WAIT_30"),
      MTProtoRPCError(code: 500, message: "INTERNAL_SERVER_ERROR"),
      MTProtoClientError.timeout, MTProtoClientError.connectionClosed, CancellationError(),
      TelegramClientError.monoforumUnsupported("channel:123"),
      TelegramClientError.userNotFound(123),
    ]
    for error in failed { #expect(!PeerAccessFailure.groupUnavailable(error), "\(error)") }
  }
  @Test func onlyRefusalsOfTheRequestMoveOnToAnotherContext() {
    #expect(PeerAccessFailure.contextRefused(MTProtoRPCError(code: 400, message: "MSG_ID_INVALID")))
    #expect(PeerAccessFailure.contextRefused(MTProtoRPCError(code: 400, message: "CHANNEL_PRIVATE")))
    #expect(PeerAccessFailure.contextRefused(MTProtoRPCError(code: 403, message: "CHAT_ADMIN_REQUIRED")))
    #expect(PeerAccessFailure.contextRefused(TelegramClientError.userNotFound(7)))
    // A flood wait is about the account, and a server failure is Telegram's own.
    #expect(!PeerAccessFailure.contextRefused(MTProtoRPCError(code: 420, message: "FLOOD_WAIT_5")))
    #expect(RequestRefusal.describes(MTProtoRPCError(code: 420, message: "FLOOD_WAIT_5")))
    #expect(!PeerAccessFailure.contextRefused(MTProtoRPCError(code: 500, message: "INTERNAL")))
    #expect(!RequestRefusal.describes(MTProtoRPCError(code: 500, message: "INTERNAL")))
    #expect(!RequestRefusal.describes(CancellationError()))
  }
  @Test func telegramsOwnTimeoutsAndInternalErrorsAreWorthAskingAgain() {
    #expect(ServerTransientFailure.describes(MTProtoRPCError(code: -503, message: "Timeout")))
    #expect(ServerTransientFailure.describes(MTProtoRPCError(code: 500, message: "MSG_WAIT_FAILED")))
    #expect(ServerTransientFailure.describes(MTProtoRPCError(code: -500, message: "No workers running")))
    #expect(ServerTransientFailure.describes(MTProtoClientError.timeout))
  }
  @Test func refusalsAndLostConnectionsAreNotWaitedOut() {
    #expect(!ServerTransientFailure.describes(MTProtoRPCError(code: 400, message: "BOT_METHOD_INVALID")))
    #expect(!ServerTransientFailure.describes(MTProtoRPCError(code: 400, message: "CHANNEL_INVALID")))
    #expect(!ServerTransientFailure.describes(MTProtoRPCError(code: 401, message: "AUTH_KEY_UNREGISTERED")))
    #expect(!ServerTransientFailure.describes(MTProtoClientError.connectionClosed))
    #expect(!ServerTransientFailure.describes(MTProtoClientError.notConnected))
    #expect(!ServerTransientFailure.describes(MTProtoClientError.protocolError(-404)))
    #expect(!ServerTransientFailure.describes(CancellationError()))
  }
  @Test func floodWaitsAreLeftToTheirOwnHandling() {
    #expect(!ServerTransientFailure.describes(MTProtoRPCError(code: 420, message: "FLOOD_WAIT_30")))
  }
  @Test func onlyUserVisibilityFailuresAreNonfatal() {
    #expect(PeerAccessFailure.userUnavailable(TelegramClientError.userNotFound(123)))
    #expect(PeerAccessFailure.userUnavailable(MTProtoRPCError(code: 400, message: "USER_ID_INVALID")))
    let unrelated: [any Error] = [
      TelegramClientError.peerNotFound("channel:123"),
      TelegramClientError.noStoredSession,
      MTProtoRPCError(code: 401, message: "AUTH_KEY_UNREGISTERED"),
      MTProtoRPCError(code: 400, message: "BOT_METHOD_INVALID"),
      MTProtoRPCError(code: 420, message: "FLOOD_WAIT_30"),
      MTProtoClientError.timeout,
      MTProtoClientError.connectionClosed,
      CancellationError(),
    ]
    for error in unrelated { #expect(!PeerAccessFailure.userUnavailable(error)) }
  }

  @Test func refusalIncludesEvery4xxAndNoOtherStatusClass() {
    for code in Int32(400)..<500 {
      #expect(RequestRefusal.describes(MTProtoRPCError(code: code, message: "REFUSED")))
    }
    for code: Int32 in [-503, -500, 200, 303, 399, 500, 599] {
      #expect(!RequestRefusal.describes(MTProtoRPCError(code: code, message: "OTHER")))
    }
    #expect(PeerAccessFailure.operationUnavailable(MTProtoRPCError(code: 403, message: "CHAT_ADMIN_REQUIRED")))
    #expect(!PeerAccessFailure.groupUnavailable(MTProtoRPCError(code: 403, message: "CHAT_ADMIN_REQUIRED")))
    #expect(!ServerTransientFailure.describes(MTProtoRPCError(code: 503, message: "SERVICE_UNAVAILABLE")))
    #expect(!TransientRPCFailure.describes(MTProtoRPCError(code: 500, message: "INTERNAL")))
    #expect(ServerTimeout.attempts == 3)
  }
}
