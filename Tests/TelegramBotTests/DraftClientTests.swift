import TelegramBot
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

private actor DraftAPITransport: TLClientTransport {
  var requests: [Data] = []
  var fail = false
  func setFailure() { fail = true }
  func send(_ requestBody: Data) throws -> Data {
    requests.append(requestBody)
    if fail { throw CancellationError() }
    return true.tlSerialized()
  }
}

@Suite struct DraftClientTests {
  @Test func parsesOnlyPrivateStopActionsWithOptionalTopic() {
    for topic: Int32? in [nil, 42] {
      let result = DraftStop.parse(
        .updateUserTyping(
          .init(
            userId: 7, topMsgId: topic,
            action: .sendMessageStopDraftAction(.init(randomId: -123)))))
      #expect(result?.userID == 7)
      #expect(result?.topicID == topic)
      #expect(result?.draftID == -123)
    }
    #expect(
      DraftStop.parse(
        .updateUserTyping(.init(userId: 7, action: .sendMessageTypingAction(.init())))) == nil)
    #expect(
      DraftStop.parse(
        .updateChatUserTyping(
          .init(
            chatId: 9, fromId: .peerUser(.init(userId: 7)),
            action: .sendMessageStopDraftAction(.init(randomId: 123))))) == nil)
    #expect(DraftStop.parse(.updateChannel(.init(channelId: 7))) == nil)
  }

  @Test func serializesPeerTopicFlagsAndRichMessage() async throws {
    let transport = DraftAPITransport()
    let client = DraftClient(api: .init(transport: transport))
    let peer = TL.InputPeerType.inputPeerUser(.init(userId: 7, accessHash: 8))
    let rich = TL.InputRichMessageType.inputRichMessage(
      .init(blocks: [
        .pageBlockParagraph(.init(text: .textPlain(.init(text: "Growing reply"))))
      ]))
    #expect(try await client.show(peer: peer, topicID: 42, richMessage: rich, draftID: -123))
    #expect(
      try await client.show(
        peer: peer, richMessage: rich, draftID: 456, canStop: false, keepOnStop: false))
    let requests = try await transport.requests.map { try TL.Messages.SetTyping(tlData: $0) }
    #expect(requests[0].peer == peer && requests[0].topMsgId == 42)
    #expect(
      requests[0].action
        == .inputSendMessageRichMessageDraftAction(
          .init(
            canStop: true,
            keepOnStop: true, randomId: -123, richMessage: rich)))
    #expect(requests[1].topMsgId == nil)
    #expect(
      requests[1].action
        == .inputSendMessageRichMessageDraftAction(.init(randomId: 456, richMessage: rich)))
    await #expect(throws: DraftClientError.zeroDraftID) {
      try await client.show(peer: peer, richMessage: rich, draftID: 0)
    }
    #expect(await transport.requests.count == 2)
    await transport.setFailure()
    await #expect(throws: CancellationError.self) {
      try await client.show(peer: peer, richMessage: rich, draftID: 123)
    }
  }
}
