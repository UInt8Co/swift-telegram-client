// The script side of a widget inspection. Each script and handler shares
// the caller's token and folding budgets, including recovered script strings.

/// What one script or handler contributes to an inspection.
struct WidgetScriptAnalysis: Equatable, Sendable {
  /// `.script(sink)` and `.scriptLiteral` candidates. Text written as HTML
  /// (`innerHTML` and the like) is not here: it is in `htmlFragments`.
  var texts: [WidgetInspection.Text] = []
  /// Constant HTML the script writes, with the sink that writes it. The
  /// inspector reads each one as markup and gives its text that sink's origin.
  var htmlFragments: [HTMLFragment] = []
  var actions: [WidgetInspection.Action] = []
  /// Constant `data:` URLs the script uses (image sources, canvas images).
  var dataURLs: [String] = []
  var features: WidgetInspection.Features = []
  var isTruncated = false

  struct HTMLFragment: Equatable, Sendable {
    var html: String
    var sink: WidgetInspection.Sink
  }
}

/// Shared budget across every script of one inspection.
struct WidgetScriptBudget: Sendable {
  var tokens: Int
  var foldingSteps: Int
  init(limits: WidgetInspection.Limits) {
    tokens = limits.maximumScriptTokens
    foldingSteps = limits.maximumFoldingSteps
  }
}

extension WidgetScriptAnalysis {
  /// Reads one script's source. `isHandler` is true for an inline `on*`
  /// attribute's value (a function body).
  static func analyze(
    _ source: String, isHandler: Bool, budget: inout WidgetScriptBudget, limits: WidgetInspection.Limits
  ) -> WidgetScriptAnalysis {
    analyze(source, budget: &budget, limits: limits, nesting: 0)
  }

  private static func analyze(
    _ source: String, budget: inout WidgetScriptBudget, limits: WidgetInspection.Limits, nesting: Int
  ) -> WidgetScriptAnalysis {
    guard !source.isEmpty else { return .init() }
    var lexer = WidgetScriptLexer(source, tokens: budget.tokens)
    let lexed = lexer.read()
    budget.tokens = lexed.remaining
    var syntax = WidgetScriptSyntax(lexed.tokens, incomplete: lexer.truncated)
    syntax.read()
    let folder = WidgetConstantFolder(syntax, steps: budget.foldingSteps, limits: limits)
    var reader = WidgetScriptSinks(folder: folder, limits: limits)
    reader.read(tokens: lexed.tokens)
    budget.foldingSteps = reader.folder.remaining
    var analysis = reader.result
    analysis.features.insert(.script)
    if lexer.malformed || (syntax.malformed && !lexer.truncated && !syntax.truncated) {
      analysis.features.insert(.malformed)
    }
    analysis.isTruncated = analysis.isTruncated || lexer.truncated || syntax.truncated
    for source in reader.dynamicSources {
      guard nesting < max(0, limits.maximumNesting), nesting < 96,
        budget.tokens > 0, budget.foldingSteps > 0 else {
        analysis.isTruncated = true
        continue
      }
      let nested = analyze(source, budget: &budget, limits: limits, nesting: nesting + 1)
      for text in nested.texts where !analysis.texts.contains(text) { analysis.texts.append(text) }
      for fragment in nested.htmlFragments where !analysis.htmlFragments.contains(fragment) { analysis.htmlFragments.append(fragment) }
      for action in nested.actions where !analysis.actions.contains(action) { analysis.actions.append(action) }
      for url in nested.dataURLs where !analysis.dataURLs.contains(url) { analysis.dataURLs.append(url) }
      analysis.features.formUnion(nested.features)
      analysis.isTruncated = analysis.isTruncated || nested.isTruncated
    }
    // Recursion shares work budgets; its combined candidates also share the
    // output limits instead of receiving a fresh allowance at every level.
    if analysis.texts.count > max(0, limits.maximumTexts) {
      analysis.texts = Array(analysis.texts.prefix(max(0, limits.maximumTexts)))
      analysis.isTruncated = true
    }
    if analysis.actions.count > max(0, limits.maximumActions) {
      analysis.actions = Array(analysis.actions.prefix(max(0, limits.maximumActions)))
      analysis.isTruncated = true
    }
    if analysis.htmlFragments.count > max(0, limits.maximumTexts) {
      analysis.htmlFragments = Array(analysis.htmlFragments.prefix(max(0, limits.maximumTexts)))
      analysis.isTruncated = true
    }
    var bytes = 0
    analysis.texts = analysis.texts.compactMap { text in
      guard text.value.utf8.count <= max(0, limits.maximumTotalTextBytes) - bytes else {
        analysis.isTruncated = true
        return nil
      }
      bytes += text.value.utf8.count
      return text
    }
    return analysis
  }
}
