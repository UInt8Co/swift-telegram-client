#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramSchema
import TelegramClient
import Testing

@Suite struct RPCRequestSummaryTests {
  @Test func rpcNamesAndPeersExcludeAccessHashesAndBodies() {
    let request = TL.Messages.SendMessage(peer: .inputPeerChannel(.init(channelId: 42, accessHash: 999999)),
      message: "PRIVATE MESSAGE", randomId: 123).tlSerialized()
    let result = RPCRequestSummary.describe(request)
    #expect(result.name == "messages.sendMessage")
    #expect(result.peer == "channel:42")
    let users = RPCRequestSummary.describe(TL.Users.GetUsers(id: [.inputUser(.init(userId: 7, accessHash: 999))]).tlSerialized())
    #expect(users.name == "users.getUsers")
    #expect(users.peer == "user:7")
    #expect(RPCRequestSummary.describe(Data([1, 2, 3])).name == "invalid TL request")
    #expect(RPCRequestSummary.describe(Data([1, 2, 3, 4])).name == "TL constructor 0x4030201")
  }

  @Test func optionalStringsVectorsAndTruncatedPeers() {
    let peer = TL.InputPeerType.inputPeerUser(.init(userId: 7, accessHash: 123456))
    for path in ["short", String(repeating: "x", count: 300)] {
      let request = TL.Messages.UploadMedia(businessConnectionId: path, peer: peer,
        media: .inputMediaEmpty(.init())).tlSerialized()
      #expect(RPCRequestSummary.describe(request).peer == "user:7")
    }
    let chats = TL.Messages.GetChats(id: [10, 20]).tlSerialized()
    #expect(RPCRequestSummary.describe(chats).peer == "chat:10 (+1 peers)")
    let request = TL.Messages.SendMessage(peer: peer, message: "hidden", randomId: 1).tlSerialized()
    for length in 4..<20 {
      #expect(RPCRequestSummary.describe(Data(request.prefix(length))).peer == nil)
    }
    #expect(RPCRequestSummary.describe(Data([0] + request).dropFirst()).peer == "user:7")
  }
}
