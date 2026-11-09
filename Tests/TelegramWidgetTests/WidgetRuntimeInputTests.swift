@testable import TelegramWidget
import Testing

@Suite struct WidgetRuntimeInputTests {
  private func fold(_ expression: String) -> WidgetScriptValue? {
    var lexer = WidgetScriptLexer(expression, tokens: 10_000)
    var syntax = WidgetScriptSyntax(lexer.read().tokens)
    syntax.read()
    var folder = WidgetConstantFolder(syntax, steps: 50_000, limits: .init())
    guard let root = syntax.nodes.indices.last else { return nil }
    return folder.evaluate(root)
  }

  @Test(arguments: [nil, #"{"text":"some message"}"#])
  func stateParsingDoesNotDisplayItsInputFallback(_ publicData: String?) {
    let script = #"""
      function render() {
        const state = JSON.parse(TelegramWidget.publicData || "{}");
        document.getElementById("card").textContent = state.text || "";
      }
      render();
      TelegramWidget.onEvent("publicDataChanged", render);
      """#
    let result = WidgetInspection(html: "<script>\(script)</script>", publicData: publicData)
    #expect(result.features.contains(.unresolvedOutput))
    #expect(!result.texts.contains { if case .script = $0.origin { return true }; return false })
    #expect(result.texts.contains(.init("{}", origin: .scriptLiteral)))
    if publicData != nil {
      #expect(result.texts.contains(.init("some message", origin: .state(.publicData, path: "text"))))
    }
  }

  @Test func literalMissingPropertyHasAConstantFallback() {
    let result = WidgetInspection(html: #"<script>x.textContent = ({a:1}).b || "y";</script>"#)
    #expect(result.texts.contains(.init("y", origin: .script(.textContent))))
    #expect(!result.features.contains(.unresolvedOutput))
    #expect(fold(#"({a:1}).b || "y""#)?.string == "y")
    #expect(fold(#"({a:1}).b || "y""#)?.isConstant == true)
  }

  @Test(arguments: [
    "TelegramWidget.publicData", "TelegramWidget.chatData",
    "TelegramWidget.viewer?.first_name", "TelegramWidget.chatType",
    "TelegramWidget.isForward", "TelegramWidget.isPreview",
    "TelegramWidget.unmodelled", "window.unmodelled", "window.TelegramWidget.publicData",
    "document.title", "document.getElementById('card').textContent",
    "location.hash", "window.location.hash", "navigator.language",
    "localStorage.getItem('k')", "window.localStorage.getItem('k')",
    "sessionStorage.getItem('k')", "Date", "Date.now()", "new Date()",
    "Math.random()", "performance.now()", "crypto.randomUUID()",
    "unknownBinding", "unknownObject.missing", "unknownObject['missing']",
    "({a:unknownBinding}).missing", "TelegramWidget['chatData']",
  ])
  func runtimeInputsStayUnknown(_ expression: String) {
    let value = fold(expression)
    #expect(value?.isConstant != true)
    #expect(value?.truthiness == nil)
    for op in ["||", "??"] {
      let fallback = "(\(expression)) \(op) 'fallback'"
      #expect(fold(fallback)?.isConstant != true)
      let result = WidgetInspection(html: "<script>x.textContent = \(fallback);</script>")
      #expect(result.features.contains(.unresolvedOutput))
      #expect(result.texts.filter { $0.origin == .script(.textContent) }.map(\.value) == ["fallback"])
      let action = WidgetInspection(html: "<script>TelegramWidget.copyText(\(fallback));</script>")
      #expect(action.actions.contains(.init(kind: .copyText, target: nil)))
      #expect(action.features.contains(.unresolvedAction))
    }
    let direct = WidgetInspection(html: "<script>x.textContent = \(expression);</script>")
    #expect(direct.features.contains(.unresolvedOutput))
    #expect(!direct.texts.contains { $0.origin == .script(.textContent) })
  }

  @Test func storageFallbackIsPossibleOutput() {
    let expression = #"localStorage.getItem("k") || "default""#
    let result = WidgetInspection(html: "<script>x.textContent = \(expression);</script>")
    #expect(result.texts.contains(.init("default", origin: .script(.textContent))))
    #expect(result.texts.contains(.init("k", origin: .scriptLiteral)))
    #expect(result.features.contains(.unresolvedOutput))
    #expect(fold(expression)?.isConstant != true)
  }

  @Test func chatDataFallbackIsPossibleOutput() {
    let expression = #"TelegramWidget.chatData || "x""#
    let result = WidgetInspection(html: "<script>x.textContent = \(expression);</script>")
    #expect(result.texts.contains(.init("x", origin: .script(.textContent))))
    #expect(result.features.contains(.unresolvedOutput))
    #expect(fold(expression)?.isConstant != true)
  }

  @Test(arguments: ["false ||", "0 ||", "null ||", "undefined ||", "null ??", "undefined ??"])
  func constantConditionsDoNotContributeToPartialOutput(_ prefix: String) {
    let result = WidgetInspection(html: "<script>x.textContent = \(prefix) ('part' + runtime);</script>")
    #expect(result.features.contains(.unresolvedOutput))
    #expect(result.texts.filter { $0.origin == .script(.textContent) }.map(\.value) == ["part"])
  }

  @Test(arguments: [nil, #"{"text":"some message"}"#])
  func stateTemplatePreservesHTMLHoles(_ publicData: String?) {
    let script = #"""
      const state = JSON.parse(TelegramWidget.publicData || "{}");
      x.innerHTML = `<b>Label</b>${state.text || ""}<i>End</i>`;
      """#
    let result = WidgetInspection(html: "<script>\(script)</script>", publicData: publicData)
    #expect(result.features.contains(.unresolvedOutput))
    #expect(result.texts.filter { $0.origin == .script(.innerHTML) }.map(\.value) == ["Label", "End"])
    #expect(result.texts.contains(.init("{}", origin: .scriptLiteral)))
    var budget = WidgetScriptBudget(limits: .init())
    let analysis = WidgetScriptAnalysis.analyze(script, isHandler: false, budget: &budget, limits: .init())
    #expect(analysis.htmlFragments == [.init(html: "<b>Label</b>\u{fffc}<i>End</i>", sink: .innerHTML)])
  }

  @Test(arguments: [
    (#"undefined || 'fallback'"#, "fallback"),
    (#"null || 'fallback'"#, "fallback"),
    (#"false || 'fallback'"#, "fallback"),
    (#"0 || 'fallback'"#, "fallback"),
    (#"-0 || 'fallback'"#, "fallback"),
    (#"NaN || 'fallback'"#, "fallback"),
    (#"'' || 'fallback'"#, "fallback"),
    (#"'value' || unknownBinding"#, "value"),
    (#"undefined ?? 'fallback'"#, "fallback"),
    (#"null ?? 'fallback'"#, "fallback"),
    (#"'value' ?? unknownBinding"#, "value"),
    (#"false ?? unknownBinding"#, "false"),
    (#"0 ?? unknownBinding"#, "0"),
    (#"1 || unknownBinding"#, "1"),
    (#"[] || unknownBinding"#, ""),
    (#"({}) || unknownBinding"#, "[object Object]"),
    (#"({a:1}).b ?? 'fallback'"#, "fallback"),
  ])
  func constantShortCircuitsStayConstant(_ expression: String, _ expected: String) {
    #expect(fold(expression)?.isConstant == true)
    let result = WidgetInspection(html: "<script>x.textContent = \(expression);</script>")
    #expect(!result.features.contains(.unresolvedOutput))
    if !expected.isEmpty {
      #expect(result.texts.contains(.init(expected, origin: .script(.textContent))))
    }
  }

  @Test(arguments: [
    "let value; x.textContent = value || 'fallback'",
    "const value = TelegramWidget.publicData; x.textContent = value || 'fallback'",
    "const {chatData: value} = TelegramWidget; x.textContent = value || 'fallback'",
    "const value = unknownObject; x.textContent = value.missing || 'fallback'",
    "function f(undefined) { x.textContent = undefined || 'fallback'; }",
    "const undefined = runtime; x.textContent = undefined || 'fallback'",
  ])
  func missingAndShadowedBindingsStayUnknown(_ source: String) {
    let result = WidgetInspection(html: "<script>\(source)</script>")
    #expect(result.features.contains(.unresolvedOutput))
    #expect(result.texts.contains(.init("fallback", origin: .script(.textContent))))
  }
}
