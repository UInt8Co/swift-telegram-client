// A closed JSON grammar. Keys are used only in paths; only string values are
// returned. Depth and node limits also apply to values supplied directly by a
// caller, which need not have passed through the payload decoder.
struct WidgetJSONReader: Sendable {
  struct Leaf: Sendable {
    var value: String
    var path: String
  }
  var leaves: [Leaf] = []
  var isValid = false
  var isTruncated = false
  private var input: [Unicode.Scalar]
  private var index = 0
  private var nodes = 0

  init(_ source: String) {
    input = Array(source.unicodeScalars)
    isValid = value(path: "", depth: 0)
    whitespace()
    isValid = isValid && index == input.count
    if !isValid { leaves = [] }
  }

  private mutating func whitespace() {
    while index < input.count, [" ", "\t", "\r", "\n"].contains(input[index]) { index += 1 }
  }

  private mutating func consume(_ c: Unicode.Scalar) -> Bool {
    whitespace()
    guard index < input.count, input[index] == c else { return false }
    index += 1
    return true
  }

  private mutating func string() -> String? {
    guard consume("\"") else { return nil }
    var output = ""
    while index < input.count {
      let c = input[index]; index += 1
      if c == "\"" { return output }
      guard c.value >= 32 else { return nil }
      if c != "\\" { output.unicodeScalars.append(c); continue }
      guard index < input.count else { return nil }
      let escape = input[index]; index += 1
      switch escape {
      case "\"", "\\", "/": output.unicodeScalars.append(escape)
      case "b": output += "\u{8}"
      case "f": output += "\u{c}"
      case "n": output += "\n"
      case "r": output += "\r"
      case "t": output += "\t"
      case "u":
        guard let high = codeUnit() else { return nil }
        var code = high
        if (0xd800...0xdbff).contains(high) {
          guard index + 2 <= input.count, input[index] == "\\", input[index + 1] == "u" else { return nil }
          index += 2
          guard let low = codeUnit(), (0xdc00...0xdfff).contains(low) else { return nil }
          code = 0x10000 + (high - 0xd800) * 1024 + low - 0xdc00
        }
        guard let scalar = Unicode.Scalar(code) else { return nil }
        output.unicodeScalars.append(scalar)
      default: return nil
      }
    }
    return nil
  }

  private mutating func codeUnit() -> UInt32? {
    guard input.count - index >= 4 else { return nil }
    var code: UInt32 = 0
    for _ in 0..<4 {
      guard let digit = WidgetReading.hex(input[index]) else { return nil }
      code = code * 16 + UInt32(digit)
      index += 1
    }
    return code
  }

  private mutating func value(path: String, depth: Int) -> Bool {
    nodes += 1
    guard depth <= 64, nodes <= 100_000 else { isTruncated = true; return false }
    whitespace()
    guard index < input.count else { return false }
    switch input[index] {
    case "\"":
      guard let text = string() else { return false }
      leaves.append(Leaf(value: text, path: path))
      return true
    case "{":
      index += 1
      if consume("}") { return true }
      while true {
        guard let key = string(), consume(":"), value(path: path.isEmpty ? key : path + "." + key, depth: depth + 1)
        else { return false }
        if consume("}") { return true }
        guard consume(",") else { return false }
      }
    case "[":
      index += 1
      if consume("]") { return true }
      var item = 0
      while true {
        guard value(path: path + "[\(item)]", depth: depth + 1) else { return false }
        item += 1
        if consume("]") { return true }
        guard consume(",") else { return false }
      }
    case "t": return literal("true")
    case "f": return literal("false")
    case "n": return literal("null")
    default: return number()
    }
  }

  private mutating func literal(_ word: String) -> Bool {
    let chars = Array(word.unicodeScalars)
    guard input.count - index >= chars.count, input[index..<(index + chars.count)].elementsEqual(chars) else { return false }
    index += chars.count
    return true
  }

  private mutating func number() -> Bool {
    if index < input.count, input[index] == "-" { index += 1 }
    guard index < input.count else { return false }
    func digit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
    if input[index] == "0" { index += 1 }
    else {
      guard digit(input[index]) else { return false }
      while index < input.count, digit(input[index]) { index += 1 }
    }
    if index < input.count, input[index] == "." {
      index += 1
      let start = index
      while index < input.count, digit(input[index]) { index += 1 }
      if index == start { return false }
    }
    if index < input.count, input[index] == "e" || input[index] == "E" {
      index += 1
      if index < input.count, input[index] == "+" || input[index] == "-" { index += 1 }
      let start = index
      while index < input.count, digit(input[index]) { index += 1 }
      if index == start { return false }
    }
    return true
  }
}
