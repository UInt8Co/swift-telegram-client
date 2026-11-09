// Coordinates independent static readers and the shared script budget. Text
// limits are applied as candidates enter the final, ordered result.
struct WidgetInspector: Sendable {
  let limits: WidgetInspection.Limits
  var result = WidgetInspection()
  private var budget: WidgetScriptBudget
  private var seen: Set<WidgetInspection.Text> = []
  private var textBytes = 0
  private var imageBytes = 0

  init(limits: WidgetInspection.Limits) {
    self.limits = limits
    budget = WidgetScriptBudget(limits: limits)
  }

  mutating func inspect(html: String, publicData: String?, chatData: String?) {
    let scripts = markup(html, origin: nil, scriptsAllowed: true)
    process(scripts, nesting: 0)
    state(publicData, field: .publicData)
    state(chatData, field: .chatData)
  }

  private mutating func text(_ candidate: WidgetInspection.Text) {
    guard !WidgetReading.trim(candidate.value).isEmpty, seen.insert(candidate).inserted else { return }
    guard result.texts.count < max(0, limits.maximumTexts) else { result.isTruncated = true; return }
    let available = min(max(0, limits.maximumTextBytes), max(0, limits.maximumTotalTextBytes) - textBytes)
    let value = WidgetReading.prefix(candidate.value, bytes: available)
    if value != candidate.value { result.isTruncated = true }
    guard !WidgetReading.trim(value).isEmpty else { return }
    let kept = WidgetInspection.Text(value, origin: candidate.origin)
    // Distinct long values may become identical after cutting them.
    guard !result.texts.contains(kept) else { return }
    textBytes += value.utf8.count
    result.texts.append(kept)
  }

  private mutating func action(_ value: WidgetInspection.Action) {
    if result.actions.count < max(0, limits.maximumActions) { result.actions.append(value) }
    else { result.isTruncated = true }
  }

  private mutating func image(_ source: String) {
    let url = WidgetReading.trim(source)
    guard url.prefix(5).lowercased() == "data:" else { return }
    guard result.images.count < max(0, limits.maximumImages) else { result.isTruncated = true; return }
    switch WidgetImageReader.decode(url, maximumBytes: max(0, limits.maximumImageBytes) - imageBytes) {
    case .image(let image):
      imageBytes += image.data.count
      result.images.append(image)
    case .tooLarge: result.isTruncated = true
    case .invalid: result.features.insert(.malformed)
    }
  }

  private mutating func state(_ source: String?, field: WidgetInspection.StateField) {
    guard let source else { return }
    let json = WidgetJSONReader(source)
    result.isTruncated = result.isTruncated || json.isTruncated
    if json.isValid {
      for leaf in json.leaves { text(.init(leaf.value, origin: .state(field, path: leaf.path))) }
    } else { text(.init(source, origin: .state(field, path: nil))) }
  }

  private enum Script: Sendable {
    case code(String, handler: Bool)
    case literal(String)
  }

  private mutating func process(_ scripts: [Script], nesting: Int) {
    for script in scripts {
      switch script {
      case .literal(let source):
        let json = WidgetJSONReader(source)
        result.isTruncated = result.isTruncated || json.isTruncated
        if json.isValid {
          for leaf in json.leaves { text(.init(leaf.value, origin: .scriptLiteral)) }
        } else { text(.init(source, origin: .scriptLiteral)) }
      case .code(let source, let handler):
        let analysis = WidgetScriptAnalysis.analyze(source, isHandler: handler, budget: &budget, limits: limits)
        merge(analysis, nesting: nesting)
      }
    }
  }

  // Kept internal so the script/markup handoff can also be tested independently
  // of which constants a particular version of the script reader recognizes.
  mutating func merge(_ analysis: WidgetScriptAnalysis, nesting: Int) {
    result.features.formUnion(analysis.features)
    result.isTruncated = result.isTruncated || analysis.isTruncated
    for candidate in analysis.texts { text(candidate) }
    for value in analysis.actions { action(value) }
    for url in analysis.dataURLs { image(url) }
    for fragment in analysis.htmlFragments {
      guard nesting < max(0, limits.maximumNesting) else { result.isTruncated = true; continue }
      let handlers = markup(fragment.html, origin: .script(fragment.sink), scriptsAllowed: false)
      process(handlers, nesting: nesting + 1)
    }
  }

  private struct Candidate: Sendable {
    var position: Int
    var sequence: Int
    var text: WidgetInspection.Text
  }
  private struct Element: Sendable {
    var name: String
    var hidden: Bool
    var scriptType: String?
    var anchor: Int?
  }
  private struct Anchor: Sendable {
    var target: String
    var label = ""
  }

  private mutating func markup(
    _ html: String, origin: WidgetInspection.Origin?, scriptsAllowed: Bool
  ) -> [Script] {
    let reader = WidgetHTMLReader(html)
    if reader.malformed { result.features.insert(.malformed) }
    var attributes: [String: [String]] = [:]
    for token in reader.tokens {
      if case .start(let tag) = token, tag.name != "noscript" {
        for attribute in tag.attributes { attributes[attribute.name, default: []].append(attribute.value) }
      }
    }
    var candidates: [Candidate] = []
    var scripts: [Script] = []
    var elements: [Element] = []
    var anchors: [Anchor] = []
    var activeAnchors: [Int] = []
    var block = ""
    var blockPosition = 0
    var hasBlockText = false
    func candidate(_ value: String, _ candidateOrigin: WidgetInspection.Origin, _ position: Int) {
      candidates.append(.init(position: position, sequence: candidates.count,
        text: .init(value, origin: origin ?? candidateOrigin)))
    }
    func flush() {
      let value = WidgetReading.collapse(block)
      if !value.isEmpty { candidate(value, .markup, blockPosition) }
      block = ""
      hasBlockText = false
    }
    func append(_ value: String, _ position: Int) {
      if !hasBlockText, !WidgetReading.trim(value).isEmpty {
        blockPosition = position
        hasBlockText = true
      }
      block += value
      for index in activeAnchors { anchors[index].label += value }
    }
    func boundary() {
      flush()
      for index in activeAnchors { anchors[index].label += " " }
    }
    for (position, token) in reader.tokens.enumerated() {
      switch token {
      case .text(let value):
        append(value, position)
        if elements.last?.hidden == true, !WidgetReading.trim(value).isEmpty { result.features.insert(.hiddenText) }
      case .start(let tag):
        if WidgetHTMLReader.blocks.contains(tag.name) { boundary() }
        let hidden = elements.last?.hidden == true || tag.value("hidden") != nil || Self.hidden(tag.value("style") ?? "")
        var anchor: Int?
        if tag.name == "canvas" { result.features.insert(.canvas) }
        if tag.name == "svg" { result.features.insert(.svg) }
        if tag.name == "script" { result.features.insert(.script) }
        if tag.name != "noscript" {
          for attribute in tag.attributes {
            if ["title", "alt", "aria-label", "placeholder", "value", "label"].contains(attribute.name) {
              candidate(WidgetReading.collapse(attribute.value), .attribute(attribute.name), position)
              if hidden, !WidgetReading.trim(attribute.value).isEmpty { result.features.insert(.hiddenText) }
            }
            if attribute.name.hasPrefix("on"), attribute.name.count > 2 {
              result.features.insert(.script)
              scripts.append(.code(attribute.value, handler: true))
            }
            if attribute.name == "style" {
              let ownAttributes = Dictionary(uniqueKeysWithValues: tag.attributes.map { ($0.name, [$0.value]) })
              let css = WidgetCSSReader(attribute.value, attributes: ownAttributes, limits: limits)
              for value in css.texts { candidate(WidgetReading.collapse(value), .styleContent, position) }
              for url in css.dataURLs { image(url) }
              result.features.formUnion(css.features)
              result.isTruncated = result.isTruncated || css.isTruncated
            }
          }
          if tag.name == "a", let href = tag.value("href") {
            let target = WidgetReading.trim(href)
            if anchors.count < max(0, limits.maximumActions) - result.actions.count {
              anchor = anchors.count
              anchors.append(.init(target: target))
            } else { result.isTruncated = true }
            if target.prefix(11).lowercased() == "javascript:" {
              result.features.insert(.script)
              scripts.append(.code(String(target.dropFirst(11)), handler: true))
            }
          }
          if tag.name == "img", let src = tag.value("src") { image(src) }
          if tag.name == "img" || tag.name == "source", let srcset = tag.value("srcset") {
            for url in WidgetImageReader.sources(srcset) { image(url) }
          }
          if tag.name == "image" {
            if let href = tag.value("href") ?? tag.value("xlink:href") { image(href) }
          }
        }
        if !tag.selfClosing, !WidgetHTMLReader.voids.contains(tag.name) {
          elements.append(.init(name: tag.name, hidden: hidden, scriptType: tag.value("type"), anchor: anchor))
          if let anchor { activeAnchors.append(anchor) }
        }
      case .end(let name):
        if WidgetHTMLReader.blocks.contains(name) { boundary() }
        if let index = elements.lastIndex(where: { $0.name == name }) {
          let closingAnchors = elements[index...].compactMap(\.anchor)
          if !closingAnchors.isEmpty { activeAnchors.removeAll { closingAnchors.contains($0) } }
          elements.removeSubrange(index...)
        } else if !WidgetHTMLReader.voids.contains(name) { result.features.insert(.malformed) }
      case .raw(let name, let source):
        switch name {
        case "noscript": break
        case "script":
          let type = WidgetReading.trim((elements.last?.scriptType ?? "").lowercased()
            .split(separator: ";", maxSplits: 1).first.map(String.init) ?? "")
          let javaScript = type.isEmpty || ["module", "text/javascript", "application/javascript", "text/ecmascript",
            "application/ecmascript", "application/x-javascript", "text/jscript", "text/livescript"].contains(type)
          scripts.append(javaScript && scriptsAllowed ? .code(source, handler: false) : .literal(source))
        case "style":
          let css = WidgetCSSReader(source, attributes: attributes, limits: limits)
          for value in css.texts { candidate(WidgetReading.collapse(value), .styleContent, position) }
          for url in css.dataURLs { image(url) }
          result.features.formUnion(css.features)
          result.isTruncated = result.isTruncated || css.isTruncated
        default:
          append(source, position)
          if elements.last?.hidden == true, !WidgetReading.trim(source).isEmpty { result.features.insert(.hiddenText) }
        }
      }
    }
    flush()
    let optionalEnds: Set<String> = ["html", "head", "body", "p", "li", "dt", "dd", "td", "th", "tr", "tbody", "thead", "tfoot", "option", "optgroup", "colgroup"]
    if elements.contains(where: { !optionalEnds.contains($0.name) }) { result.features.insert(.malformed) }
    for item in candidates.sorted(by: { ($0.position, $0.sequence) < ($1.position, $1.sequence) }) { text(item.text) }
    for anchor in anchors { action(.init(kind: .anchor, target: anchor.target, label: WidgetReading.collapse(anchor.label))) }
    return scripts
  }

  private static func hidden(_ source: String) -> Bool {
    let declarations = source.lowercased().split(separator: ";").compactMap { declaration -> (String, String)? in
      let parts = declaration.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      return (WidgetReading.trim(String(parts[0])), WidgetReading.trim(String(parts[1].split(separator: "!", maxSplits: 1).first ?? "")))
    }
    var values: [String: String] = [:]
    for (name, value) in declarations { values[name] = WidgetReading.trim(value) }
    func zero(_ value: String?) -> Bool {
      guard let value else { return false }
      let numeric = value.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
      return !numeric.isEmpty && Double(numeric) == 0
    }
    return values["display"] == "none" || values["visibility"] == "hidden" || zero(values["opacity"])
      || zero(values["font-size"]) || ((zero(values["width"]) || zero(values["height"]))
        && (values["overflow"] == "hidden" || values["overflow-x"] == "hidden" || values["overflow-y"] == "hidden"))
  }
}
