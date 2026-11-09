import TelegramMarkup
import TelegramSchema
import TelegramWidget
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// Original HTML fixtures compressed offline with Python's zlib, level 9.
private enum SummaryFixtures {
  static let complete: [UInt8] = [120, 218, 125, 81, 193, 78, 220, 48, 16, 253, 21, 43, 23, 167, 18, 74, 182, 82, 203, 33, 235, 68, 10, 11, 162, 42, 75, 161, 108, 160, 103, 39, 153, 117, 44, 28, 219, 181, 39, 101, 87, 136, 127, 175, 205, 42, 66, 98, 17, 62, 120, 198, 158, 247, 158, 103, 252, 152, 173, 206, 148, 233, 30, 9, 107, 43, 132, 29, 178, 188, 173, 88, 110, 43, 38, 71, 65, 184, 194, 50, 185, 149, 29, 78, 14, 18, 226, 93, 87, 38, 61, 71, 94, 200, 145, 11, 200, 133, 220, 46, 91, 238, 225, 244, 219, 201, 221, 66, 93, 222, 156, 171, 161, 254, 93, 175, 234, 186, 44, 147, 3, 255, 61, 195, 106, 49, 51, 228, 195, 217, 205, 221, 211, 226, 234, 82, 152, 58, 172, 95, 155, 251, 225, 226, 94, 196, 244, 34, 110, 171, 160, 192, 201, 224, 96, 91, 38, 3, 162, 245, 69, 158, 195, 142, 143, 86, 65, 134, 224, 49, 79, 170, 159, 70, 106, 150, 243, 138, 121, 220, 43, 168, 178, 93, 81, 180, 176, 53, 14, 158, 59, 163, 17, 52, 22, 201, 38, 86, 72, 28, 43, 121, 97, 249, 1, 199, 124, 231, 164, 197, 106, 151, 73, 173, 193, 253, 104, 174, 215, 164, 36, 52, 140, 191, 121, 45, 144, 249, 23, 232, 146, 52, 160, 64, 56, 62, 254, 145, 189, 0, 204, 140, 5, 61, 95, 173, 165, 126, 76, 233, 220, 26, 102, 35, 204, 253, 209, 47, 71, 196, 206, 216, 125, 19, 100, 83, 26, 51, 242, 143, 171, 233, 35, 88, 212, 127, 213, 117, 147, 70, 57, 194, 49, 194, 193, 223, 41, 76, 159, 210, 16, 220, 254, 3, 137, 39, 174, 84, 8, 30, 116, 223, 56, 174, 61, 239, 80, 26, 157, 82, 124, 59, 124, 194, 146, 66, 159, 7, 183, 82, 26, 51, 30, 93, 143, 96, 15, 216, 132, 110, 204, 132, 105, 240, 195, 129, 31, 78, 200, 215, 197, 177, 138, 157, 90, 37, 187, 40, 176, 36, 27, 116, 82, 139, 108, 235, 204, 184, 26, 184, 91, 153, 30, 210, 211, 239, 129, 51, 233, 201, 67, 159, 210, 181, 68, 112, 92, 17, 109, 48, 62, 18, 220, 57, 216, 242, 31, 201, 91, 229, 48]
  static let hostile: [UInt8] = [120, 218, 179, 41, 176, 83, 43, 44, 205, 47, 177, 86, 75, 7, 226, 156, 18, 235, 226, 228, 162, 204, 130, 18, 16, 79, 1, 196, 213, 47, 73, 215, 45, 207, 76, 73, 79, 5, 11, 217, 232, 23, 216, 217, 100, 230, 166, 43, 36, 230, 148, 216, 42, 225, 210, 168, 100, 103, 147, 168, 144, 81, 148, 154, 134, 79, 9, 54, 195, 19, 237, 0, 129, 65, 47, 192]
  static let budget: [UInt8] = [120, 218, 179, 41, 176, 115, 203, 44, 42, 46, 177, 209, 47, 176, 179, 41, 176, 11, 78, 77, 206, 207, 75, 1, 115, 18, 21, 50, 138, 82, 211, 108, 149, 244, 243, 82, 43, 74, 148, 236, 220, 243, 109, 244, 19, 237, 0, 118, 254, 15, 58]
  static let literals: [UInt8] = [120, 218, 179, 41, 176, 115, 204, 41, 74, 77, 76, 169, 84, 40, 206, 200, 47, 207, 179, 209, 47, 176, 179, 41, 78, 46, 202, 44, 40, 81, 40, 169, 44, 72, 181, 85, 74, 44, 40, 200, 201, 76, 78, 44, 201, 204, 207, 211, 207, 42, 206, 207, 83, 178, 139, 86, 66, 209, 162, 164, 163, 148, 152, 4, 36, 20, 21, 21, 129, 228, 163, 57, 43, 32, 8, 200, 246, 78, 77, 45, 80, 72, 203, 44, 42, 46, 1, 114, 12, 141, 140, 97, 66, 57, 137, 64, 145, 88, 27, 125, 136, 61, 118, 0, 60, 150, 46, 67]
  static let unicode: [UInt8] = [120, 218, 179, 41, 176, 83, 80, 112, 78, 76, 59, 188, 146, 139, 243, 195, 252, 153, 77, 169, 103, 26, 21, 20, 20, 74, 18, 51, 115, 20, 108, 244, 11, 236, 0, 184, 150, 11, 83]
  static let empty: [UInt8] = [120, 218, 3, 0, 0, 0, 0, 1]
}

@Suite struct WidgetSummaryTests {
  private func render(
    _ bytes: [UInt8], limits: WidgetSummaryLimits = .init(), publicData: String? = nil,
    chatData: String? = nil
  ) -> MarkupRenderer.Output {
    MarkupRenderer(widgets: .summary(limits)).render(.messageMediaWidget(.init(
      width: 0, height: 0, payload: Data(bytes), publicData: publicData,
      publicDataHash: publicData == nil ? nil : 1, chatData: chatData)))
  }

  @Test func rendersOrderedSummary() {
    let output = MarkupRenderer(widgets: .summary(.init())).render(.messageMediaWidget(.init(
      isCopy: true, canQuery: true, backgroundQuery: true,
      width: 320, height: 200, payload: Data(SummaryFixtures.complete),
      publicData: #"{"items":[{"title":"State text"}]}"#, publicDataHash: 1,
      chatData: "Chat text", widgetId: 42)))
    #expect(output.markup == """
      <tg-widget id="42" width="320" height="200" copy can-query background-query features="script timers reads-state unresolved-action character-codes requests wallet">
      <tg-widget-action type="anchor" target="https://example.test/">Join</tg-widget-action>
      <tg-widget-action type="open-telegram-link" target="https://t.me/example"/>
      <tg-widget-action type="copy-text" target="copy value"/>
      <tg-widget-action type="open-link" unresolved/>
      <tg-widget-action type="request" target="query"/>
      <tg-widget-action type="wallet-send-transaction" target="transaction"/>
      <tg-widget-action type="wallet-sign-data" target="signature"/>
      <tg-widget-text>Block text</tg-widget-text>
      <tg-widget-text from="attribute" name="alt">Picture</tg-widget-text>
      <tg-widget-text>Join</tg-widget-text>
      <tg-widget-text from="style">Style text</tg-widget-text>
      <tg-widget-text from="script" sink="inner-html">Script text</tg-widget-text>
      <tg-widget-state name="public-data" path="items[0].title">State text</tg-widget-state>
      <tg-widget-state name="chat-data">Chat text</tg-widget-state>
      <tg-widget-literal>Literal note</tg-widget-literal>
      <tg-widget-images count="2" formats="gif png"/>
      </tg-widget>
      """)
    #expect(output.isComplete)
  }

  @Test func escapesTextAndAttributes() {
    let output = render(SummaryFixtures.hostile, publicData: #"{"\"><script>":"</tg-widget>"}"#)
    #expect(output.markup == """
      <tg-widget>
      <tg-widget-action type="anchor" target="&quot;&gt;&lt;script&gt;">&lt;/tg-widget&gt;</tg-widget-action>
      <tg-widget-text>"&gt;&lt;script&gt; &lt;/tg-widget&gt;</tg-widget-text>
      <tg-widget-text from="attribute" name="alt">"&gt;&lt;script&gt;</tg-widget-text>
      <tg-widget-text>&lt;/tg-widget&gt;</tg-widget-text>
      <tg-widget-state name="public-data" path="&quot;&gt;&lt;script&gt;">&lt;/tg-widget&gt;</tg-widget-state>
      </tg-widget>
      """)
    #expect(output.isComplete)
  }

  @Test func prioritizesActionsAndStopsAtFirstChildThatDoesNotFit() {
    let expected = """
      <tg-widget truncated>
      <tg-widget-action type="anchor" target="/next">Go</tg-widget-action>
      </tg-widget>
      """
    let output = render(SummaryFixtures.budget, limits: .init(maximumCharacters: expected.count))
    #expect(output.markup == expected)
    #expect(output.isComplete)
    let all = render(SummaryFixtures.budget).markup
    #expect(render(SummaryFixtures.budget, limits: .init(maximumCharacters: all.count)).markup == all)
    // The flag costs space too, and can displace the last accepted child.
    let short = render(SummaryFixtures.budget, limits: .init(maximumCharacters: all.count - 1)).markup
    #expect(short.count <= all.count - 1)
    #expect(short.contains(" truncated>"))
    #expect(!short.contains("<tg-widget-text>Go"))
  }

  @Test(arguments: [0, -1, 1])
  func alwaysWritesHeaderForSmallBudgets(_ maximum: Int) {
    let output = render(SummaryFixtures.budget, limits: .init(maximumCharacters: maximum))
    #expect(output.markup == "<tg-widget truncated>\n</tg-widget>")
    #expect(output.isComplete)
  }

  @Test func normalizesAndCutsValuesAtCharacterBoundaries() {
    #expect(render(SummaryFixtures.unicode).markup == "<tg-widget>\n<tg-widget-text>Café 🙂é tail</tg-widget-text>\n</tg-widget>")
    #expect(render(SummaryFixtures.unicode, limits: .init(maximumValueCharacters: 8)).markup
      == "<tg-widget truncated>\n<tg-widget-text>Café 🙂é…</tg-widget-text>\n</tg-widget>")
    for maximum in [0, -1] {
      #expect(render(SummaryFixtures.unicode, limits: .init(maximumValueCharacters: maximum)).markup
        == "<tg-widget truncated>\n<tg-widget-text></tg-widget-text>\n</tg-widget>")
    }
  }

  @Test func countsEscapedCharactersInBudget() {
    let all = render(SummaryFixtures.hostile).markup
    let output = render(SummaryFixtures.hostile, limits: .init(maximumCharacters: all.count - 1))
    #expect(output.markup.count <= all.count - 1)
    #expect(output.markup.contains(" truncated>"))
  }

  @Test func reportsInspectionLimitsWithoutChangingCompleteness() {
    let output = render(SummaryFixtures.budget, limits: .init(inspection: .init(maximumTexts: 1)))
    #expect(output.markup.contains(" truncated>"))
    #expect(output.markup.contains("<tg-widget-text>First</tg-widget-text>"))
    #expect(!output.markup.contains("Second"))
    #expect(output.isComplete)
  }

  @Test func invalidPayloadKeepsMediaHeader() {
    let output = MarkupRenderer(widgets: .summary(.init())).render(.messageMediaWidget(.init(
      isCopy: true, canQuery: true, backgroundQuery: true, width: 320, height: 200,
      payload: Data([0]), widgetId: 42)))
    #expect(output.markup == #"<tg-widget id="42" width="320" height="200" copy can-query background-query invalid/>"#)
    #expect(output.isComplete)
    #expect(render([]).markup == "<tg-widget invalid/>")
  }

  @Test func staticAndSharedHeadersOmitOnlyAbsentValues() {
    #expect(render(SummaryFixtures.empty).markup == "<tg-widget>\n</tg-widget>")
    let output = MarkupRenderer(widgets: .summary(.init())).render(.messageMediaWidget(.init(
      width: 0, height: 200, payload: Data(SummaryFixtures.empty), widgetId: 0)))
    #expect(output.markup == "<tg-widget id=\"0\" height=\"200\">\n</tg-widget>")
  }

  @Test func filtersLiteralsAndPreservesTheirOrder() {
    #expect(render(SummaryFixtures.literals).markup == """
      <tg-widget features="script">
      <tg-widget-text>Already shown</tg-widget-text>
      <tg-widget-literal>Keep first</tg-widget-literal>
      <tg-widget-literal>123</tg-widget-literal>
      <tg-widget-literal>Keep last</tg-widget-literal>
      </tg-widget>
      """)
  }

  @Test func configurationRemainsMutableAndMarkerIsDefault() {
    var renderer = MarkupRenderer()
    #expect(renderer.widgets == .marker)
    renderer.widgets = .summary(.init())
    #expect(renderer.render(.messageMediaWidget(.init(width: 0, height: 0, payload: Data()))).markup
      == "<tg-widget invalid/>")
  }
}
