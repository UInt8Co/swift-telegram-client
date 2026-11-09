// The script side of a widget inspection. Each script and handler shares
// the caller's token and folding budgets, including recovered script strings.

/// What one script or handler contributes to an inspection.
struct WidgetScriptAnalysis: Equatable, Sendable {
  /// `.script(sink)` and `.scriptLiteral` candidates. Text written as HTML
  /// (`innerHTML` and the like) is not here: it is in `htmlFragments`.
  var texts: [WidgetInspection.Text] = []
  enum Event: Equatable, Sendable {
    case text(WidgetInspection.Text)
    case fragment(HTMLFragment, nesting: Int)
    case action(WidgetInspection.Action)
    case dataURL(String)
    case code(String, nesting: Int)
  }
  var events: [Event] = []
  /// Constant HTML the script writes, with the sink that writes it. The
  /// inspector reads each one as markup and gives its text that sink's origin.
  var htmlFragments: [HTMLFragment] = []
  var actions: [WidgetInspection.Action] = []
  /// Constant `data:` URLs the script uses (image sources, canvas images).
  var dataURLs: [String] = []
  var features: WidgetInspection.Features = []
  var isTruncated = false

  struct HTMLFragment: Hashable, Sendable {
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
    _ source: String, isHandler: Bool, budget: inout WidgetScriptBudget, limits: WidgetInspection.Limits,
    nesting: Int = 0, limitOutput: Bool = true, deferCode: Bool = false
  ) -> WidgetScriptAnalysis {
    analyze(source, budget: &budget, limits: limits, nesting: nesting, limitOutput: limitOutput, deferCode: deferCode)
  }

  private static func analyze(
    _ source: String, budget: inout WidgetScriptBudget, limits: WidgetInspection.Limits,
    nesting: Int, limitOutput: Bool, deferCode: Bool
  ) -> WidgetScriptAnalysis {
    guard !source.isEmpty else { return .init() }
    var lexer = WidgetScriptLexer(source, tokens: budget.tokens)
    let lexed = lexer.read()
    budget.tokens = lexed.remaining
    var syntax = WidgetScriptSyntax(lexed.tokens, incomplete: lexer.truncated)
    syntax.read()
    let folder = WidgetConstantFolder(syntax, steps: budget.foldingSteps, limits: limits, nesting: nesting)
    var reader = WidgetScriptSinks(folder: folder, limits: limits)
    reader.read(tokens: lexed.tokens)
    budget.foldingSteps = reader.folder.remaining
    var analysis = reader.result
    analysis.features.insert(.script)
    if lexer.malformed || (syntax.malformed && !lexer.truncated && !syntax.truncated) {
      analysis.features.insert(.malformed)
    }
    analysis.isTruncated = analysis.isTruncated || lexer.truncated || syntax.truncated
    analysis.events = []
    for event in reader.orderedEvents.sorted(by: { ($0.position, $0.sequence) < ($1.position, $1.sequence) }) {
      if case .code(let source, let depth) = event.value, !deferCode {
        guard depth < max(0, limits.maximumNesting), depth < 96,
          budget.tokens > 0, budget.foldingSteps > 0 else {
          analysis.isTruncated = true
          continue
        }
        let nested = analyze(source, budget: &budget, limits: limits, nesting: depth + 1, limitOutput: false, deferCode: false)
        analysis.events += nested.events
        analysis.features.formUnion(nested.features)
        analysis.isTruncated = analysis.isTruncated || nested.isTruncated
      } else { analysis.events.append(event.value) }
    }
    analysis.texts = []
    analysis.actions = []
    analysis.htmlFragments = []
    analysis.dataURLs = []
    var seen: Set<WidgetInspection.Text> = []
    var bytes = 0
    analysis.events = analysis.events.compactMap { event in
      switch event {
      case .text(let text):
        if !limitOutput { analysis.texts.append(text); return event }
        if seen.contains(text) { return nil }
        let available = min(max(0, limits.maximumTextBytes), max(0, limits.maximumTotalTextBytes) - bytes)
        let value = WidgetReading.prefix(text.value, bytes: available)
        if value != text.value { analysis.isTruncated = true }
        let kept = WidgetInspection.Text(value, origin: text.origin)
        guard !WidgetReading.trim(value).isEmpty, !seen.contains(kept) else { return nil }
        guard analysis.texts.count < max(0, limits.maximumTexts) else { analysis.isTruncated = true; return nil }
        seen.insert(kept)
        bytes += value.utf8.count
        analysis.texts.append(kept)
        return .text(kept)
      case .fragment(let fragment, _): analysis.htmlFragments.append(fragment)
      case .action(let action):
        if limitOutput && analysis.actions.count >= max(0, limits.maximumActions) { analysis.isTruncated = true; return nil }
        analysis.actions.append(action)
      case .dataURL(let url): analysis.dataURLs.append(url)
      case .code: break
      }
      return event
    }
    return analysis
  }
}
