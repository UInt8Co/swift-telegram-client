import Testing
@testable import TelegramBot

@Suite struct BotCommandParserTests {
  @Test func commandParsing() {
    for text in ["/help", "/help@OwnBot", "@OwnBot /help", "/help @OwnBot", "  @ownbot\n/help  ", "/help something"] {
      #expect(BotCommandParser.parse(text, botUsername: "OwnBot", guestMentions: .adjacentAndTrailing) != nil)
    }
    for text in ["/help@OtherBot", "please /help", "@OtherBot /help", "/help@OtherBot @OwnBot", ""] {
      #expect(BotCommandParser.parse(text, botUsername: "OwnBot", guestMentions: .adjacentAndTrailing) == nil)
    }
  }

  @Test func argumentsPreserveOriginalText() {
    for text in [
      "/help Quoted Text\nRepeated  spacing",
      "/HELP@OWNBOT Quoted Text\nRepeated  spacing",
      "  @OwnBot /help Quoted Text\nRepeated  spacing \n",
      "/help @OwnBot Quoted Text\nRepeated  spacing",
      "/help Quoted Text\nRepeated  spacing @OwnBot",
    ] {
      #expect(BotCommandParser.parse(text, botUsername: "OwnBot", guestMentions: .adjacentAndTrailing)?.arguments == "Quoted Text\nRepeated  spacing")
    }
    #expect(BotCommandParser.parse("/help    ", botUsername: "OwnBot", guestMentions: .adjacentAndTrailing) == ParsedBotCommand(command: "help", arguments: nil))
    #expect(BotCommandParser.parse("/help @OwnBot", botUsername: "@OwnBot", guestMentions: .adjacentAndTrailing) == ParsedBotCommand(command: "help", arguments: nil))
    #expect(BotCommandParser.parse("/help targeting @OwnBot with text", botUsername: "OwnBot", guestMentions: .adjacentAndTrailing)?.arguments == "targeting @OwnBot with text")
    #expect(BotCommandParser.parse("/help @OtherBot example", botUsername: "OwnBot", guestMentions: .adjacentAndTrailing)?.arguments == "@OtherBot example")
    #expect(BotCommandParser.parse("/help@OtherBot arguments", botUsername: "OwnBot", guestMentions: .adjacentAndTrailing) == nil)
    #expect(BotCommandParser.parse("@OwnBot /help@OtherBot arguments", botUsername: "OwnBot", guestMentions: .adjacentAndTrailing) == nil)
    #expect(BotCommandParser.parse("/helpful reason", botUsername: "OwnBot", guestMentions: .adjacentAndTrailing)?.command == "helpful")
    #expect(BotCommandParser.parse("/help reason", botUsername: "not a username") == nil)
  }

  @Test func guestMentionsAreOptIn() {
    #expect(BotCommandParser.parse("@sample /help", botUsername: "sample") == nil)
    #expect(BotCommandParser.parse("/help @sample", botUsername: "sample")?.arguments == "@sample")
    #expect(BotCommandParser.parse("/help@other", botUsername: "sample") == nil)
  }
  @Test func usernameValidationKeepsShortAndMaximumLengthNames() {
    for name in ["a", "@A", "Z_9", String(repeating: "a", count: 32)] {
      #expect(BotCommandParser.parse("/help", botUsername: name)?.command == "help")
    }
    for name in ["", "@", "@@a", "1a", "_a", "a-b", "é", " a", String(repeating: "a", count: 33)] {
      #expect(BotCommandParser.parse("/help", botUsername: name) == nil)
    }
  }

  @Test func anyOfSeveralUsernamesAddressesTheBot() {
    let names = ["OwnBot", "@SecondName"]
    for text in [
      "/help", "/help@OwnBot", "/help@secondname", "@SecondName /help", "/help @SecondName",
      "@OwnBot /help@SecondName", "/help @OwnBot", "/help @secondname",
    ] {
      #expect(BotCommandParser.parse(text, botUsernames: names, guestMentions: .adjacentAndTrailing) == ParsedBotCommand(command: "help", arguments: nil))
    }
    #expect(BotCommandParser.parse("@SecondName /help reason text @OwnBot", botUsernames: names, guestMentions: .adjacentAndTrailing)?.arguments == "reason text")
    #expect(BotCommandParser.parse("/help @OtherBot", botUsernames: names, guestMentions: .adjacentAndTrailing)?.arguments == "@OtherBot")
    for text in ["/help@OtherBot", "@OtherBot /help", "/help@SecondNameX"] {
      #expect(BotCommandParser.parse(text, botUsernames: names, guestMentions: .adjacentAndTrailing) == nil)
    }
    // A single name keeps its previous behaviour; invalid names are ignored.
    #expect(BotCommandParser.parse("/help@SecondName", botUsername: "OwnBot") == nil)
    #expect(BotCommandParser.parse("/help@OwnBot", botUsernames: ["not valid", "OwnBot"]) != nil)
    #expect(BotCommandParser.parse("/help", botUsernames: ["not valid"]) == nil)
    #expect(BotCommandParser.parse("/help", botUsernames: [String]()) == nil)
  }
}
