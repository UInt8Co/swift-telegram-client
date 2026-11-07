import TelegramBot
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct BotLinkTests {
  @Test func parametersRoundTripArbitraryBytesAndEnforceLimits() throws {
    for size in 0...45 {
      let data = Data((0..<size).map { UInt8(($0 * 93) % 256) })
      let parameter = try #require(BotLink.encodeStartParameter(data, prefix: "x_"))
      #expect(parameter.utf8.count <= 64)
      #expect(BotLink.decodeStartParameter(parameter, prefix: "x_") == data)
    }
    #expect(BotLink.encodeStartParameter(Data(repeating: 1, count: 48))?.count == 64)
    #expect(BotLink.encodeStartParameter(Data(repeating: 1, count: 49)) == nil)
    #expect(BotLink.encodeStartParameter(Data(), prefix: "bad!") == nil)
    for invalid in ["", "Zg==", "Zh", "Zg+", "Zg/", "Zg\n", "😀", String(repeating: "a", count: 65)]
    {
      #expect(BotLink.decodeStartParameter(invalid) == nil)
    }
    #expect(BotLink.decodeStartParameter("eA", prefix: "x_") == nil)
  }
  @Test func linksAndButtonsKeepNativeTelegramTypes() {
    #expect(
      BotLink.startURL(botUsername: "@example_bot", parameter: "eA")
        == "https://t.me/example_bot?start=eA")
    #expect(BotLink.startURL(botUsername: "bot/other", parameter: "eA") == nil)
    #expect(BotLink.startURL(botUsername: "", parameter: "eA") == nil)
    #expect(BotLink.startURL(botUsername: "example_bot", parameter: "bad&start=x") == nil)
    #expect(
      BotLink.urlButton("Open", url: "https://t.me/example_bot")
        == .init(text: "Open", type: .inlineButtonTypeUrl(.init(url: "https://t.me/example_bot"))))
  }

  @Test func groupLinksUseTelegramPermissionNamesAndValidateInputs() {
    #expect(
      BotLink.startGroupURL(
        botUsername: "@example_bot", parameter: "group", adminRights: [.deleteMessages, .banUsers])
        == "https://t.me/example_bot?startgroup=group&admin=delete_messages+restrict_members")
    #expect(
      BotLink.startGroupURL(
        botUsername: "example_bot", parameter: "x_-1", adminRights: [.inviteUsers, .inviteUsers])
        == "https://t.me/example_bot?startgroup=x_-1&admin=invite_users")
    #expect(
      BotLink.startGroupURL(botUsername: "example_bot", parameter: "group", adminRights: [])
        == "https://t.me/example_bot?startgroup=group")
    for username in ["", "@", "bot/other", "bot-name", "bot?start=x", "бот"] {
      #expect(
        BotLink.startGroupURL(botUsername: username, parameter: "group", adminRights: [.banUsers])
          == nil)
    }
    for parameter in [
      "", "bad&admin=promote_members", "bad+value", "😀", String(repeating: "a", count: 65),
    ] {
      #expect(
        BotLink.startGroupURL(
          botUsername: "example_bot", parameter: parameter, adminRights: [.banUsers]) == nil)
    }
    #expect(
      BotLink.startGroupURL(
        botUsername: "example_bot", parameter: String(repeating: "a", count: 64),
        adminRights: [.banUsers]) != nil)
  }
}

@Suite struct BotLinkUsernameCompatibilityTests {
  @Test func permissiveUsernamesRemainAccepted() {
    for name in ["_name", "123", String(repeating: "a", count: 33)] {
      #expect(BotLink.startURL(botUsername: name, parameter: "ok") != nil)
    }
  }
}
