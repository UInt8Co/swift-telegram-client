// Drives one inspection: reads the markup, CSS and state, and hands every
// script and handler to `WidgetScriptAnalysis`. Replaced by the markup reader.

struct WidgetInspector {
  let limits: WidgetInspection.Limits
  var result = WidgetInspection()

  init(limits: WidgetInspection.Limits) { self.limits = limits }

  mutating func inspect(html: String, publicData: String?, chatData: String?) {}
}
