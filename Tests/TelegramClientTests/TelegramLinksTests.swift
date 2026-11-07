import TelegramClient
import Testing

@Suite struct TelegramLinksTests {
  @Test func destinationRoutes() {
    for link in ["https://t.me/Example", "telegram.me/EXAMPLE", "https://t.me/Example/123",
                 "https://t.me/s/Example/123", "tg://resolve?domain=Example"] {
      #expect(TelegramLink.destinations(inURL: link) == [.username("example")])
    }
    for link in ["https://t.me/addemoji/Pack", "tg://addemoji?set=pack"] {
      #expect(TelegramLink.destinations(inURL: link) == [.emojiSet("pack")])
    }
    for link in ["https://t.me/addstickers/PACK", "tg://addstickers?set=Pack"] {
      #expect(TelegramLink.destinations(inURL: link) == [.stickerSet("pack")])
    }
    for link in ["https://t.me/+InvitationToken", "https://t.me/share/url?url=https://example.com",
                 "https://t.me/joinchat/abcdef", "https://t.me/boost/example", "https://t.me/c/100/1"] {
      #expect(TelegramLink.destinations(inURL: link).isEmpty)
    }
  }

  @Test func numericUserLinksDecodeOnce() {
    for link in ["tg://user?id=42", "TG://USER?id=00042", "tg://user?%69d=%34%32", "tg://user?id=42#ignored"] {
      #expect(TelegramLink.destinations(inURL: link) == [.user(42)])
    }
    #expect(TelegramLink.telegramUserID(inURL: "tg://user?id=9223372036854775807") == Int64.max)
  }

  @Test func usernameRulesRemainExplicit() {
    #expect(TelegramUsername.normalized("@Example") == "example")
    for name in ["_name", "123", String(repeating: "a", count: 33)] {
      #expect(TelegramUsername.normalized(name) == nil)
      #expect(PeerLocator("@" + name) == .username(name))
    }
    for name in ["", "a-b", "é", "a b", "@@Name"] {
      #expect(TelegramUsername.normalized(name) == nil)
    }
    #expect(TelegramLink.packName(String(repeating: "A", count: 64)) == String(repeating: "a", count: 64))
    #expect(TelegramLink.packName(String(repeating: "A", count: 65)) == nil)
    #expect(TelegramLink.packName("1Pack") == nil)
  }

  @Test(arguments: [
    "tg://user", "tg://user?id", "tg://user?id=", "tg://user?id=0", "tg://user?id=-42",
    "tg://user?id=9223372036854775808", "tg://user?id=+42", "tg://user?id=4.2",
    "tg://user?id=42x", "tg://user?id=%2042", "tg://user?id=%2B42", "tg://user?id=%00%34%32",
    "tg://user?id=%2534%2532", "tg://user?id=%FF", "tg://user?id=%4", "tg://user?id=４２",
    "tg://user?id=42&id=43", "tg://user?id=42&%69d=42", "tg://user?ID=42", "tg://user?other=42",
    "https://user?id=42", "ftp://user?id=42", "tg://other?id=42", "tg://user.example?id=42",
    "tg://user.?id=42", "tg://%75ser?id=42", "tg://login@user?id=42", "tg://user:80?id=42",
    "tg://user/path?id=42", "tg://user/a/..?id=42", "tg:user?id=42",
    "https://t.me/c/42/1", "tg://privatepost?channel=42&post=1", "tg://join?invite=42",
  ])
  func unrelatedOrMalformedURLsNeverNameAUser(_ url: String) {
    #expect(TelegramLink.telegramUserID(inURL: url) == nil)
    #expect(!TelegramLink.destinations(inURL: url).contains { if case .user = $0 { true } else { false } })
  }
}
