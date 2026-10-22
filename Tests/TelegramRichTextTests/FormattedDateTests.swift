import TelegramRichText
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct FormattedDateTests {
  // 2026-10-20 14:03:05.75 UTC
  private let moment = Date(timeIntervalSince1970: 1_792_504_985.75)

  @Test func sendsNativeDateWithEachFormatFlagAndSurvivesSerialization() throws {
    let message = RichMessage {
      Paragraph {
        Text("Updated ")
        FormattedDate(moment, format: [.relative, .longDate, .dayOfWeek]).bold()
      }
    }
    let decoded = try TL.InputRichMessageType(tlData: message.richMessage.tlSerialized())
    guard case .inputRichMessage(let rich) = decoded,
      case .pageBlockParagraph(let paragraph) = rich.blocks.first,
      case .textConcat(let concat) = paragraph.text,
      case .textBold(let bold) = concat.texts.last,
      case .textDate(let date) = bold.text
    else {
      Issue.record("Expected a bold native date in the paragraph")
      return
    }
    #expect(rich.blocks == message.blocks)
    #expect(date.date == 1_792_504_985)
    #expect(date.relative && date.longDate && date.dayOfWeek)
    #expect(!date.shortTime && !date.longTime && !date.shortDate)
    #expect(message.text == "Updated 2026-10-20 14:03 UTC")
  }

  static let fallbacks: [(FormattedDate.Format, String)] = [
    ([], "2026-10-20 14:03 UTC"),
    (.dateTime, "2026-10-20 14:03 UTC"),
    ([.longDate, .longTime], "2026-10-20 14:03:05 UTC"),
    (.shortDate, "2026-10-20"),
    ([.longDate, .dayOfWeek], "2026-10-20"),
    (.shortTime, "14:03 UTC"),
    (.longTime, "14:03:05 UTC"),
    (.relative, "2026-10-20 14:03 UTC"),
  ]

  @Test(arguments: fallbacks)
  func defaultFallbackShowsOnlyTheRequestedPartsInUTC(
    format: FormattedDate.Format, fallback: String
  ) {
    let date = FormattedDate(moment, format: format)
    #expect(RichMessage.plainText(date.richText) == fallback)
    guard case .textDate(let value) = date.richText else {
      Issue.record("Expected a native date")
      return
    }
    #expect(value.shortDate == format.contains(.shortDate))
    #expect(value.shortTime == format.contains(.shortTime))
  }

  @Test func customFallbackKeepsItsFormattingAndOutOfRangeDatesClamp() throws {
    let date = FormattedDate(moment, format: .shortDate, fallback: Text("today").italic())
    guard case .textDate(let value) = date.richText else {
      Issue.record("Expected a native date")
      return
    }
    #expect(value.text == .textItalic(.init(text: Text("today").richText)))
    for (input, expected) in [(Date.distantFuture, Int32.max), (.distantPast, .min)] {
      guard case .textDate(let value) = FormattedDate(input).richText else {
        Issue.record("Expected a native date")
        return
      }
      #expect(value.date == expected)
    }
    // Copying received content keeps the date as an input constructor.
    let blocks = Paragraph(date).blocks
    #expect(RichMessage.inputBlocks(blocks) == blocks)
    _ = try RichMessage.inputMessage(blocks: blocks)
  }
}
