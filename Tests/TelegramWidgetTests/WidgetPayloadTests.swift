import TelegramSchema
import TelegramWidget
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// Original byte fixtures, compressed offline with zlib level 9.
enum WidgetPayloadFixtures {
  static let html: [UInt8] = [120, 218, 179, 41, 176, 243, 72, 205, 201, 201, 215, 81, 40, 207, 76, 73, 79, 45, 81, 180, 209, 47, 176, 3, 0, 77, 176, 6, 233]
  static let invalidUTF8: [UInt8] = [120, 218, 251, 255, 15, 0, 2, 254, 1, 254]
  static let nul: [UInt8] = [120, 218, 179, 41, 176, 99, 176, 209, 47, 176, 3, 0, 9, 7, 2, 4]
  static let large: [UInt8] = [120, 218, 237, 193, 1, 1, 0, 0, 0, 128, 144, 219, 205, 239, 8, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 104, 146, 238, 3, 253]
  static let boundary: [UInt8] = [120, 218, 237, 193, 1, 1, 0, 0, 0, 128, 144, 219, 205, 239, 8, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 24, 142, 241, 3, 133]
  static let gzip: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 2, 3, 179, 41, 176, 243, 72, 205, 201, 201, 215, 81, 40, 207, 76, 73, 79, 45, 81, 180, 209, 47, 176, 3, 0, 53, 35, 189, 111, 21, 0, 0, 0]
  static let raw: [UInt8] = [179, 41, 176, 243, 72, 205, 201, 201, 215, 81, 40, 207, 76, 73, 79, 45, 81, 180, 209, 47, 176, 3, 0]
}

@Suite struct WidgetPayloadTests {
  @Test func roundTripsLevelNineZlib() throws {
    #expect(try WidgetPayload.html(fromPayload: Data(WidgetPayloadFixtures.html)) == "<p>Hello, widget!</p>")
  }

  @Test func acceptsExactlyTheHTMLByteLimit() throws {
    #expect(try WidgetPayload.html(fromPayload: Data(WidgetPayloadFixtures.boundary)).utf8.count == 32_768)
  }

  @Test(arguments: [[], [120], [0, 0], [136, 28], [121, 24], WidgetPayloadFixtures.gzip, WidgetPayloadFixtures.raw])
  func rejectsNonZlibHeaders(_ bytes: [UInt8]) {
    #expect(throws: WidgetPayload.DecodingError.notZlib) {
      try WidgetPayload.html(fromPayload: Data(bytes))
    }
  }

  @Test func rejectsPresetDictionary() {
    #expect(throws: WidgetPayload.DecodingError.corrupt) {
      try WidgetPayload.html(fromPayload: Data([0x78, 0x20, 0, 0, 0, 0]))
    }
  }

  @Test func rejectsDamagedStreams() {
    var badAdler = WidgetPayloadFixtures.html
    badAdler[badAdler.count - 1] ^= 1
    var damaged = WidgetPayloadFixtures.html
    damaged[2] = 0xff
    for bytes in [Array(WidgetPayloadFixtures.html.prefix(2)), Array(WidgetPayloadFixtures.html.dropLast()), badAdler, damaged] {
      #expect(throws: WidgetPayload.DecodingError.corrupt) {
        try WidgetPayload.html(fromPayload: Data(bytes))
      }
    }
  }

  @Test func limitsInflationBeforeDecoding() {
    #expect(WidgetPayloadFixtures.large.count < 100)
    #expect(throws: WidgetPayload.DecodingError.tooLarge) {
      try WidgetPayload.html(fromPayload: Data(WidgetPayloadFixtures.large))
    }
  }

  @Test func rejectsInvalidUTF8() {
    #expect(throws: WidgetPayload.DecodingError.invalidUTF8) {
      try WidgetPayload.html(fromPayload: Data(WidgetPayloadFixtures.invalidUTF8))
    }
  }

  @Test func rejectsNUL() {
    #expect(throws: WidgetPayload.DecodingError.containsNUL) {
      try WidgetPayload.html(fromPayload: Data(WidgetPayloadFixtures.nul))
    }
  }

  @Test func decodesReceivedMediaAndFlags() throws {
    let media = TL.MessageMediaWidget(isCopy: true, canQuery: true, backgroundQuery: true,
      width: 300, height: 180, payload: Data(WidgetPayloadFixtures.html),
      publicData: "shared", publicDataHash: 19, chatData: "chat", widgetId: 42)
    let content = try WidgetContent(media)
    #expect(content == WidgetContent(html: "<p>Hello, widget!</p>", publicData: "shared", chatData: "chat",
      widgetID: 42, width: 300, height: 180, isCopy: true, canQuery: true, backgroundQuery: true))
  }

  @Test func decodesInlinePreview() throws {
    let inline = TL.BotInlineMessageWidget(width: 320, height: 200, payload: Data(WidgetPayloadFixtures.html),
      publicData: "shared", chatData: "chat", widgetId: 43, message: "Caption")
    #expect(try WidgetContent(inline) == WidgetContent(html: "<p>Hello, widget!</p>", publicData: "shared",
      chatData: "chat", widgetID: 43, width: 320, height: 200))
  }

  @Test func constructorsPropagateDecodingFailure() {
    #expect(throws: WidgetPayload.DecodingError.notZlib) {
      try WidgetContent(TL.MessageMediaWidget(width: 0, height: 0, payload: Data()))
    }
    #expect(throws: WidgetPayload.DecodingError.notZlib) {
      try WidgetContent(TL.BotInlineMessageWidget(width: 0, height: 0, payload: Data(), message: ""))
    }
  }
}
