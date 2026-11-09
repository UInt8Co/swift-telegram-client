// The script side of a widget inspection. `WidgetInspector` calls `analyze`
// for every `<script>` block and inline `on*` handler; this file is replaced
// by the script analyser (lexer, bounded constant folder, sink detection).

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
    var analysis = WidgetScriptAnalysis()
    if !source.isEmpty { analysis.features.insert(.script) }
    return analysis
  }
}
