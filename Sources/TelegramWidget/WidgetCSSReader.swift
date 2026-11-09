struct WidgetCSSReader: Sendable {
  var texts: [String] = []
  var dataURLs: [String] = []
  var features: WidgetInspection.Features = []
  var isTruncated = false
  private var input: [Unicode.Scalar]
  private var index = 0
  private var work: WidgetMarkupBudget
  private var seen: Set<String> = []
  private var textBytes = 0

  init(_ source: String, attributes: [[String: String]], limits: WidgetInspection.Limits, budget: inout WidgetMarkupBudget) {
    work = budget
    let bounded = WidgetReading.prefix(source, bytes: work.remaining)
    _ = work.charge(bounded.utf8.count)
    if bounded != source { work.truncated = true }
    input = Array(bounded.unicodeScalars)
    while index < input.count, work.remaining > 0 {
      skipSpaceAndComments()
      guard index < input.count else { break }
      if input[index] == "\"" || input[index] == "'" { _ = string(); continue }
      let atRule = take("@")
      let name = identifier()
      if name.isEmpty { index += 1; continue }
      if atRule, name == "keyframes" || name.hasSuffix("-keyframes") { features.insert(.styleAnimation) }
      skipSpaceAndComments()
      if name == "url", take("(") {
        let url = urlBody()
        if url.lowercased().hasPrefix("data:") { dataURLs.append(url) }
      } else if take(":") {
        if name == "animation" || name.hasPrefix("animation-") || name == "transition"
          || name.hasPrefix("transition-") || name.hasSuffix("-animation") || name.hasSuffix("-transition")
        { features.insert(.styleAnimation) }
        if name == "content" { content(attributes: attributes, limits: limits) }
      }
    }
    isTruncated = isTruncated || work.truncated
    budget = work
  }

  private mutating func take(_ c: Unicode.Scalar) -> Bool {
    guard index < input.count, input[index] == c else { return false }
    index += 1
    return true
  }

  private mutating func skipSpaceAndComments() {
    while index < input.count {
      if WidgetReading.space(input[index]) { index += 1; continue }
      if input[index] == "/", index + 1 < input.count, input[index + 1] == "*" {
        index += 2
        while index + 1 < input.count, !(input[index] == "*" && input[index + 1] == "/") { index += 1 }
        if index + 1 < input.count { index += 2 }
        else { index = input.count; features.insert(.malformed) }
        continue
      }
      break
    }
  }

  private mutating func identifier() -> String {
    var output = ""
    while index < input.count {
      let c = input[index]
      if c == "\\" { output += escape(); continue }
      guard c == "-" || c == "_" || c.value >= 128 || (65...90).contains(c.value)
        || (97...122).contains(c.value) || (48...57).contains(c.value) else { break }
      output.unicodeScalars.append(c)
      index += 1
    }
    return output.lowercased()
  }

  private mutating func escape() -> String {
    index += 1
    guard index < input.count else { features.insert(.malformed); return "" }
    if input[index] == "\n" || input[index] == "\r" || input[index] == "\u{c}" {
      let c = input[index]; index += 1
      if c == "\r", index < input.count, input[index] == "\n" { index += 1 }
      return ""
    }
    var code: UInt32 = 0
    var count = 0
    while index < input.count, count < 6, let digit = WidgetReading.hex(input[index]) {
      code = code * 16 + UInt32(digit)
      index += 1; count += 1
    }
    if count > 0 {
      if index < input.count, WidgetReading.space(input[index]) {
        let c = input[index]; index += 1
        if c == "\r", index < input.count, input[index] == "\n" { index += 1 }
      }
      return String((code == 0 ? nil : Unicode.Scalar(code)) ?? "\u{fffd}")
    }
    let c = input[index]; index += 1
    return String(c)
  }

  private mutating func string() -> String {
    let quote = input[index]; index += 1
    var output = ""
    while index < input.count {
      let c = input[index]
      if c == quote { index += 1; return output }
      if c == "\\" { output += escape() }
      else { output.unicodeScalars.append(c); index += 1 }
    }
    features.insert(.malformed)
    return output
  }

  private mutating func urlBody() -> String {
    skipSpaceAndComments()
    var output = ""
    if index < input.count, input[index] == "\"" || input[index] == "'" {
      output = string()
      skipSpaceAndComments()
    } else {
      while index < input.count, input[index] != ")" {
        if input[index] == "\\" { output += escape() }
        else { output.unicodeScalars.append(input[index]); index += 1 }
      }
    }
    if !take(")") { features.insert(.malformed) }
    return WidgetReading.trim(output)
  }

  private mutating func content(attributes: [[String: String]], limits: WidgetInspection.Limits) {
    // Parse once; each expansion uses exactly one element's attributes.
    var parts: [(attribute: Bool, value: String)] = []
    var functions = 0
    while index < input.count {
      skipSpaceAndComments()
      guard index < input.count else { break }
      let c = input[index]
      if functions == 0, c == ";" || c == "}" { break }
      if c == "\"" || c == "'" {
        let part = string()
        if functions == 0 { parts.append((false, part)) }
        continue
      }
      if c == ")" { functions = max(0, functions - 1); index += 1; continue }
      let name = identifier()
      if name.isEmpty { index += 1; continue }
      skipSpaceAndComments()
      guard take("(") else { continue }
      if name == "url" {
        let url = urlBody()
        if url.lowercased().hasPrefix("data:") { dataURLs.append(url) }
      } else if name == "attr", functions == 0 {
        skipSpaceAndComments()
        let attribute = identifier()
        skipSpaceAndComments()
        if take(")") { parts.append((true, attribute)) }
        else { functions += 1 }
      } else { functions += 1 }
    }
    if functions != 0 { features.insert(.malformed) }
    guard !parts.isEmpty else { return }
    guard limits.maximumTexts > 0 else { isTruncated = true; return }
    let hasAttributes = parts.contains { $0.attribute }
    let elements = hasAttributes ? attributes : [[:]]
    for element in elements {
      guard work.charge(parts.count) else { isTruncated = true; return }
      if hasAttributes && !parts.contains(where: { $0.attribute && element[$0.value] != nil }) { continue }
      var value = ""
      var bytes = 0
      for part in parts {
        let piece = part.attribute ? element[part.value, default: ""] : part.value
        guard work.charge(bytes + piece.utf8.count + 1) else { isTruncated = true; return }
        let combined = value + piece
        value = WidgetReading.prefix(combined, bytes: limits.maximumTextBytes)
        bytes = value.utf8.count
        if value != combined { isTruncated = true; break }
      }
      guard !WidgetReading.trim(value).isEmpty else { continue }
      guard work.charge(bytes), !seen.contains(value) else {
        if work.truncated { isTruncated = true; return }
        continue
      }
      guard texts.count < max(0, limits.maximumTexts), bytes <= max(0, limits.maximumTotalTextBytes) - textBytes else {
        isTruncated = true; return
      }
      seen.insert(value)
      texts.append(value)
      textBytes += bytes
    }
  }
}
