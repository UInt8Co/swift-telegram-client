struct WidgetCSSReader: Sendable {
  var texts: [String] = []
  var dataURLs: [String] = []
  var features: WidgetInspection.Features = []
  var isTruncated = false
  private var input: [Unicode.Scalar]
  private var index = 0

  init(_ source: String, attributes: [String: [String]], limits: WidgetInspection.Limits) {
    input = Array(source.unicodeScalars)
    while index < input.count {
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

  private mutating func content(attributes: [String: [String]], limits: WidgetInspection.Limits) {
    var values = [""]
    var hasPart = false
    var functions = 0
    while index < input.count {
      skipSpaceAndComments()
      guard index < input.count else { break }
      let c = input[index]
      if functions == 0, c == ";" || c == "}" { break }
      if c == "\"" || c == "'" {
        let part = string()
        if functions == 0 {
          hasPart = true
          values = values.map { bounded($0 + part, limits: limits) }
        }
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
        // The simple attr(name) form has no fallback or type annotation.
        skipSpaceAndComments()
        if take(")") {
          hasPart = true
          let parts = attributes[attribute] ?? [""]
          var expanded: [String] = []
          var seen: Set<String> = []
          for prefix in values {
            for part in parts {
              let value = bounded(prefix + part, limits: limits)
              guard seen.insert(value).inserted else { continue }
              if expanded.count < max(1, limits.maximumTexts) { expanded.append(value) }
              else { isTruncated = true }
            }
          }
          values = expanded
        } else { functions += 1 }
      } else { functions += 1 }
    }
    if functions != 0 { features.insert(.malformed) }
    if hasPart { texts += values }
  }

  private mutating func bounded(_ value: String, limits: WidgetInspection.Limits) -> String {
    if value.utf8.count > max(0, limits.maximumTextBytes) {
      isTruncated = true
      return WidgetReading.prefix(value, bytes: limits.maximumTextBytes)
    }
    return value
  }
}
