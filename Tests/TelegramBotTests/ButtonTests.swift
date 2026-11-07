import TelegramBot
import TelegramRichText
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct ButtonTests {
  @Test func buttonsEmitNativeActionsAndLiteralTitles() throws {
    let data = Data([0, 255, 1])
    let message = RichMessage {
      Paragraph("Actions")
      ButtonRow {
        RichButton.callback("<Undo> **now**", data: data, style: .danger)
        RichButton.url("Visit", "https://example.com", style: .link)
        RichButton.copy("Copy", text: "literal <text>")
      }
    }
    let expected = TL.PageBlockType.pageBlockButtonRow(
      .init(
        alignLeft: true,
        buttons: [
          .init(
            text: Text("<Undo> **now**").richText,
            type: .inlineButtonTypeCallback(.init(data: data)),
            style: .init(bgDanger: true)),
          .init(
            text: Text("Visit").richText,
            type: .inlineButtonTypeUrl(.init(url: "https://example.com")),
            style: .init(link: true)),
          .init(
            text: Text("Copy").richText,
            type: .inlineButtonTypeCopy(.init(copyText: "literal <text>"))),
        ]))
    #expect(message.blocks.last == expected)
    #expect(message.text == "Actions\n<Undo> **now**\nVisit\nCopy")
    #expect(try message.richMessage == .inputRichMessage(.init(blocks: message.blocks)))
    #expect(try TL.PageBlockType(tlData: expected.tlSerialized()) == expected)
  }

  @Test func stylesAndAlignmentsUseTheirFlags() throws {
    let styles: [TL.RichButtonStyle?] = [
      nil, .init(bgPrimary: true), .init(bgDanger: true),
      .init(bgSuccess: true), .init(link: true),
    ]
    for alignment in ButtonRow.Alignment.allCases {
      let row = ButtonRow(alignment: alignment) {
        for style in RichButton.Style.allCases {
          RichButton.callback("Go", data: Data([1]), style: style)
        }
      }
      guard case .pageBlockButtonRow(let native) = try #require(row.blocks.first) else {
        Issue.record("Expected a button row")
        return
      }
      #expect(native.alignLeft == (alignment == .leading))
      #expect(native.alignCenter == (alignment == .center))
      #expect(native.alignRight == (alignment == .trailing))
      #expect(native.buttons.map(\.style) == styles)
      #expect(
        try RichMessage(blocks: row.blocks).richMessage
          == .inputRichMessage(.init(blocks: row.blocks)))
    }
  }

  @Test func stretchedRowHasNoAlignmentFlags() throws {
    let message = RichMessage {
      ButtonRow(alignment: .stretched) { RichButton.callback("Go", data: Data([1])) }
    }
    let expected = TL.PageBlockType.pageBlockButtonRow(
      .init(buttons: [
        .init(text: Text("Go").richText, type: .inlineButtonTypeCallback(.init(data: Data([1]))))
      ]))
    #expect(message.blocks == [expected])
    #expect(try TL.PageBlockType(tlData: expected.tlSerialized()) == expected)
    #expect(try message.richMessage == .inputRichMessage(.init(blocks: [expected])))
  }

  @Test func buildersComposeArraysBranchesAndOptionalContent() {
    let include = true
    let row = ButtonRow {
      [RichButton.copy("A", text: "a"), RichButton.copy("B", text: "b")]
      if include { RichButton.copy("C", text: "c") }
      if !include { RichButton.copy("Wrong", text: "x") }
      if include { RichButton.copy("D", text: "d") } else { RichButton.copy("Wrong", text: "x") }
    }
    #expect(RichMessage(blocks: row.blocks).text == "A\nB\nC\nD")
    #expect(ButtonRow {}.blocks.isEmpty)
    #expect(ButtonRow { if !include { RichButton.copy("Wrong", text: "x") } }.blocks.isEmpty)
  }

  @Test func callbackLimitsCountBytesAndAcceptBothBoundaries() throws {
    for count in [0, 65, 256] {
      #expect(!RichButton.isValidCallbackData(Data(repeating: 1, count: count)))
    }
    for count in [1, 64] {
      let data = Data(repeating: 255, count: count)
      #expect(RichButton.isValidCallbackData(data))
      let row = ButtonRow { RichButton.callback("Button", data: data) }
      _ = try RichMessage(blocks: row.blocks).richMessage
    }
    #expect(RichButton.isValidCallbackData(Data(String(repeating: "😀", count: 16).utf8)))
    #expect(!RichButton.isValidCallbackData(Data(String(repeating: "😀", count: 17).utf8)))
  }

  @Test func upstreamConversionAndValidationReachButtonText() throws {
    let received = TL.PageBlockType.pageBlockButtonRow(
      .init(buttons: [
        .init(
          text: .textButton(
            .init(
              text: .textMention(.init(text: Text("@name").richText)),
              type: .inlineButtonTypeCopy(.init(copyText: "copy")))),
          type: .inlineButtonTypeCallback(.init(data: Data([1]))))
      ]))
    let message = RichMessage(blocks: [received])
    #expect(message.text == "@name")
    guard case .inputRichMessage(let input) = try message.richMessage,
      case .pageBlockButtonRow(let row) = try #require(input.blocks.first),
      case .textButton(let text) = try #require(row.buttons.first).text
    else {
      Issue.record("Expected nested native button")
      return
    }
    #expect(text.text == Text("@name").richText)
    let tooLong = RichMessage {
      ButtonRow { RichButton.copy(String(repeating: "a", count: 32_769), text: "x") }
    }
    #expect(throws: RichMessageValidationError.textTooLong) { try tooLong.richMessage }
  }
}
