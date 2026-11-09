import TelegramSchema
import TelegramWidget

/// How a received HTML widget appears in rendered markup.
public enum WidgetRendering: Equatable, Sendable {
  /// An opaque `<tg-media type="widget"/>` marker, without decoding the payload.
  case marker
  /// A bounded static reading of text, actions, state and image metadata.
  case summary(WidgetSummaryLimits)
}

/// Bounds for a static widget summary, independent of message completeness.
public struct WidgetSummaryLimits: Equatable, Sendable {
  /// Maximum characters in the whole escaped element, including tags and newlines.
  /// The header and closing tag are always written, even if they exceed this limit.
  public var maximumCharacters: Int
  /// Maximum characters per normalized value, including a final `…` when cut.
  /// Nonpositive limits keep an empty value; characters are Swift `Character`s.
  public var maximumValueCharacters: Int
  /// Limits passed to the widget's static inspection.
  public var inspection: WidgetInspection.Limits

  public init(
    maximumCharacters: Int = 4_096, maximumValueCharacters: Int = 512,
    inspection: WidgetInspection.Limits = .init()
  ) {
    self.maximumCharacters = maximumCharacters
    self.maximumValueCharacters = maximumValueCharacters
    self.inspection = inspection
  }
}

extension Writer {
  mutating func widget(_ media: TL.MessageMediaWidget, limits: WidgetSummaryLimits) {
    var attributes: [Attribute] = []
    if let id = media.widgetId { attributes.append(.init("id", String(id))) }
    if media.width != 0 { attributes.append(.init("width", String(media.width))) }
    if media.height != 0 { attributes.append(.init("height", String(media.height))) }
    if media.isCopy { attributes.append(.init("copy")) }
    if media.canQuery { attributes.append(.init("can-query")) }
    if media.backgroundQuery { attributes.append(.init("background-query")) }
    guard let content = try? WidgetContent(media) else {
      void("tg-widget", attributes + [.init("invalid")])
      return
    }
    let inspection = WidgetInspection(content, limits: limits.inspection)
    let features = widgetFeatureNames.filter { inspection.features.contains($0.0) }.map(\.1)
    if !features.isEmpty { attributes.append(.init("features", features.joined(separator: " "))) }
    var summary = WidgetSummary(limits: limits, truncated: inspection.isTruncated)
    summary.read(inspection)
    output += summary.render(attributes: attributes)
  }
}

private struct WidgetSummary {
  let limits: WidgetSummaryLimits
  var truncated: Bool
  var children: [String] = []

  // Normalize before cutting, then let Writer apply its usual escaping.
  mutating func value(_ source: String) -> String {
    let normalized = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let maximum = max(0, limits.maximumValueCharacters)
    guard normalized.count > maximum else { return normalized }
    truncated = true
    return maximum == 0 ? "" : String(normalized.prefix(maximum - 1)) + "…"
  }

  mutating func child(_ name: String, _ attributes: [Attribute] = [], text: String? = nil) {
    let tag = Writer.openTag(name, attributes)
    if let text {
      children.append(tag + MarkupRenderer.escape(text) + "</\(name)>")
    } else {
      children.append(String(tag.dropLast()) + "/>")
    }
  }

  mutating func read(_ inspection: WidgetInspection) {
    for action in inspection.actions {
      var attributes = [Attribute("type", widgetKebabCase(action.kind.rawValue))]
      if let target = action.target { attributes.append(.init("target", value(target))) }
      else { attributes.append(.init("unresolved")) }
      let label = action.label.map { value($0) }
      child("tg-widget-action", attributes, text: label)
    }
    for text in inspection.texts {
      var attributes: [Attribute] = []
      switch text.origin {
      case .markup: break
      case .attribute(let name): attributes = [.init("from", "attribute"), .init("name", value(name))]
      case .styleContent: attributes = [.init("from", "style")]
      case .script(let sink): attributes = [.init("from", "script"), .init("sink", widgetKebabCase(sink.rawValue))]
      case .state, .scriptLiteral: continue
      }
      let rendered = value(text.value)
      child("tg-widget-text", attributes, text: rendered)
    }
    for text in inspection.texts {
      guard case .state(let field, let path) = text.origin else { continue }
      var attributes = [Attribute("name", widgetKebabCase(field.rawValue))]
      if let path { attributes.append(.init("path", value(path))) }
      let rendered = value(text.value)
      child("tg-widget-state", attributes, text: rendered)
    }
    let shown = Set(inspection.texts.filter { $0.origin.isShown }.map(\.value))
    for text in inspection.texts {
      guard text.origin == .scriptLiteral, !shown.contains(text.value), text.value.count >= 3,
        text.value.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
      let rendered = value(text.value)
      child("tg-widget-literal", text: rendered)
    }
    if !inspection.images.isEmpty {
      let formats = Set(inspection.images.map { $0.format.rawValue }).sorted().joined(separator: " ")
      child("tg-widget-images", [.init("count", String(inspection.images.count)), .init("formats", formats)])
    }
  }

  func render(attributes: [Attribute]) -> String {
    func fit(truncated: Bool) -> (String, Bool) {
      let header = Writer.openTag("tg-widget", attributes + (truncated ? [.init("truncated")] : []))
      let closing = "\n</tg-widget>"
      var result = header
      var count = header.count + closing.count
      for child in children {
        let addition = child.count + 1
        guard count <= limits.maximumCharacters, addition <= limits.maximumCharacters - count else {
          return (result + closing, true)
        }
        result += "\n" + child
        count += addition
      }
      return (result + closing, count > limits.maximumCharacters)
    }
    let first = fit(truncated: truncated)
    // Adding the truncation flag may itself displace a previously fitting child.
    return first.1 && !truncated ? fit(truncated: true).0 : first.0
  }
}

private func widgetKebabCase(_ source: String) -> String {
  let characters = Array(source)
  var result = ""
  for (index, character) in characters.enumerated() {
    if character.isUppercase, index > 0,
      characters[index - 1].isLowercase || (index + 1 < characters.count && characters[index + 1].isLowercase) {
      result += "-"
    }
    result += character.lowercased()
  }
  return result
}

// The public Features declaration order is also the summary's display order.
private let widgetFeatureNames: [(WidgetInspection.Features, String)] = [
  (.script, "script"), (.timers, "timers"), (.styleAnimation, "style-animation"),
  (.readsState, "reads-state"), (.watchesState, "watches-state"), (.storage, "storage"),
  (.readsContext, "reads-context"), (.clockOrRandomness, "clock-or-randomness"),
  (.unresolvedOutput, "unresolved-output"), (.unresolvedAction, "unresolved-action"),
  (.dynamicCode, "dynamic-code"), (.characterCodes, "character-codes"), (.base64, "base64"),
  (.uriDecoding, "uri-decoding"), (.canvas, "canvas"), (.canvasText, "canvas-text"),
  (.svg, "svg"), (.hiddenText, "hidden-text"), (.requests, "requests"), (.wallet, "wallet"),
  (.malformed, "malformed"),
]
