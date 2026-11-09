import TelegramWidget
import Testing

@Suite struct WidgetInspectionContractTests {
  @Test func onlyUnprovenScriptLiteralsAreNotShown() {
    #expect(!WidgetInspection.Origin.scriptLiteral.isShown)
    #expect(WidgetInspection.Origin.markup.isShown)
    #expect(WidgetInspection.Origin.script(.textContent).isShown)
    #expect(WidgetInspection.Origin.state(.publicData, path: "title").isShown)
  }
}
