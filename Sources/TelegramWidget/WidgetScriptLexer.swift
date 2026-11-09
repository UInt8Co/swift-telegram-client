/// A lexical token, with cooked UTF-16 for JavaScript strings. Keeping code
/// units here preserves surrogate pairs assembled by separate expressions.
struct WidgetScriptToken: Sendable {
  enum Kind: Sendable {
    case word, punctuation, number(Double), string([UInt16]), quasi([UInt16]), regex, invalid
  }
  var kind: Kind
  var text: String
}

/// A forgiving, bounded lexer. Templates share the ordinary token stream, so
/// interpolation can contain strings, object literals and further templates.
struct WidgetScriptLexer: Sendable {
  private var input: [Unicode.Scalar]
  private var position = 0
  private var tokens: [WidgetScriptToken] = []
  private var remaining: Int
  private(set) var malformed = false
  private(set) var truncated = false
  private var expectsOperand = true
  private var controlParentheses: [Bool] = []
  private var lineStart = true

  init(_ source: String, tokens: Int) {
    input = Array(source.unicodeScalars)
    remaining = max(0, tokens)
  }

  mutating func read() -> (tokens: [WidgetScriptToken], remaining: Int) {
    scan(interpolation: false, depth: 0)
    return (tokens, remaining)
  }

  private func scalar(_ offset: Int = 0) -> Unicode.Scalar? {
    let i = position + offset
    return i < input.count ? input[i] : nil
  }

  private func starts(_ text: String) -> Bool {
    let value = Array(text.unicodeScalars)
    return position + value.count <= input.count
      && input[position..<(position + value.count)].elementsEqual(value)
  }

  private mutating func emit(_ kind: WidgetScriptToken.Kind, _ text: String = "") {
    guard remaining > 0 else { truncated = true; return }
    remaining -= 1
    tokens.append(.init(kind: kind, text: text))
  }

  private func isLine(_ c: Unicode.Scalar) -> Bool {
    c == "\n" || c == "\r" || c.value == 0x2028 || c.value == 0x2029
  }

  private func isWord(_ c: Unicode.Scalar, first: Bool = false) -> Bool {
    c == "$" || c == "_" || c.properties.isIDStart
      || (!first && (c.properties.isIDContinue || c.value == 0x200C || c.value == 0x200D))
  }

  private func digit(_ c: Unicode.Scalar) -> Int? {
    switch c.value {
    case 48...57: Int(c.value - 48)
    case 65...70: Int(c.value - 55)
    case 97...102: Int(c.value - 87)
    default: nil
    }
  }

  private mutating func scan(interpolation: Bool, depth: Int) {
    guard depth < 96 else { truncated = true; position = input.count; return }
    var braces = 0
    var objectBraces: [Bool] = []
    while position < input.count && !truncated {
      guard let c = scalar() else { break }
      if c.properties.isWhitespace || c.value == 0xFEFF {
        if isLine(c) { lineStart = true }
        position += 1
        continue
      }
      if starts("//") || starts("<!--") || (lineStart && starts("-->")) {
        while let c = scalar(), !isLine(c) { position += 1 }
        continue
      }
      if starts("/*") {
        position += 2
        while position < input.count && !starts("*/") {
          if let c = scalar(), isLine(c) { lineStart = true }
          position += 1
        }
        if starts("*/") { position += 2 } else { malformed = true }
        continue
      }
      guard remaining > 0 else { truncated = true; break }
      lineStart = false
      if interpolation && c == "}" && braces == 0 {
        position += 1
        emit(.punctuation, "}")
        return
      }
      if c == "'" || c == "\"" {
        position += 1
        let value = quoted(c, template: false)
        emit(value.valid ? .string(value.units) : .invalid)
        expectsOperand = false
        continue
      }
      if c == "`" {
        template(depth: depth + 1)
        expectsOperand = false
        continue
      }
      if isWord(c, first: true) || c == "\\" {
        var word = ""
        var valid = true
        while let c = scalar(), isWord(c) || c == "\\" {
          if c == "\\" {
            position += 1
            guard scalar() == "u" else { malformed = true; valid = false; break }
            position += 1
            if let value = unicodeEscape(), let s = Unicode.Scalar(value), isWord(s, first: word.isEmpty) {
              word.unicodeScalars.append(s)
            } else { malformed = true; valid = false; break }
          } else {
            word.unicodeScalars.append(c)
            position += 1
          }
        }
        emit(valid ? .word : .invalid, word)
        expectsOperand = ["return", "throw", "case", "delete", "void", "typeof", "new", "in", "of", "yield", "await", "else", "do"].contains(word)
        continue
      }
      if (48...57).contains(c.value) || (c == "." && scalar(1).map { (48...57).contains($0.value) } == true) {
        number()
        expectsOperand = false
        continue
      }
      if c == "/" && expectsOperand {
        regex()
        expectsOperand = false
        continue
      }
      let operators = [">>>=", "===", "!==", "**=", "&&=", "||=", "??=", ">>>", "<<=", ">>=", "...", "=>", "==", "!=", "<=", ">=", "++", "--", "+=", "-=", "*=", "/=", "%=", "^=", "|=", "&=", "<<", ">>", "&&", "||", "??", "?.", "**"]
      let op = operators.first(where: { starts($0) }) ?? String(c)
      position += op.unicodeScalars.count
      if op == "{" {
        braces += 1
        let previous = tokens.last?.text ?? ""
        objectBraces.append(["=", "(", "[", ",", ":", "return", "${"].contains(previous))
      }
      let objectEnd = op == "}" ? (objectBraces.popLast() ?? false) : false
      if op == "}" { braces = max(0, braces - 1) }
      if op == "(" {
        controlParentheses.append(["if", "while", "for", "with", "switch", "catch"].contains(tokens.last?.text ?? ""))
      }
      let controlEnd = op == ")" ? (controlParentheses.popLast() ?? false) : false
      emit(.punctuation, op)
      expectsOperand = controlEnd || (!objectEnd && ![ ")", "]", "++", "--", ".", "?." ].contains(op))
    }
    if interpolation && !truncated { malformed = true }
  }

  private mutating func hex(_ count: Int) -> UInt32? {
    var value: UInt32 = 0
    for _ in 0..<count {
      guard let c = scalar(), let d = digit(c) else { return nil }
      value = value * 16 + UInt32(d)
      position += 1
    }
    return value
  }

  private mutating func unicodeEscape() -> UInt32? {
    if scalar() != "{" { return hex(4) }
    position += 1
    var value: UInt32 = 0
    var count = 0
    while let c = scalar(), c != "}" {
      guard let d = digit(c), value <= 0x10FFFF / 16 else { return nil }
      value = value * 16 + UInt32(d)
      guard value <= 0x10FFFF else { return nil }
      count += 1
      position += 1
    }
    guard count > 0, scalar() == "}", value <= 0x10FFFF else { return nil }
    position += 1
    return value
  }

  private func units(_ value: UInt32) -> [UInt16] {
    if value <= 0xFFFF { return [UInt16(value)] }
    let v = value - 0x10000
    return [UInt16(0xD800 + (v >> 10)), UInt16(0xDC00 + (v & 1023))]
  }

  private mutating func escape(template: Bool) -> [UInt16]? {
    guard let c = scalar() else { return nil }
    position += 1
    if isLine(c) {
      if c == "\r" && scalar() == "\n" { position += 1 }
      return []
    }
    switch c {
    case "n": return [10]
    case "r": return [13]
    case "t": return [9]
    case "b": return [8]
    case "f": return [12]
    case "v": return [11]
    case "x": return hex(2).map { units($0) }
    case "u": return unicodeEscape().map { units($0) }
    case "0"..."7":
      if c == "0", scalar().map({ !(48...57).contains($0.value) }) ?? true { return [0] }
      if template { return nil }
      var v = c.value - 48
      let count = c.value <= 51 ? 2 : 1
      for _ in 0..<count {
        guard let s = scalar(), (48...55).contains(s.value) else { break }
        v = v * 8 + s.value - 48
        position += 1
      }
      return [UInt16(v)]
    case "8", "9": return template ? nil : units(c.value)
    default: return units(c.value)
    }
  }

  private mutating func quoted(_ quote: Unicode.Scalar, template: Bool) -> (units: [UInt16], valid: Bool) {
    var result: [UInt16] = []
    var valid = true
    while let c = scalar() {
      if c == quote {
        position += 1
        return (result, valid)
      }
      if !template && (c == "\n" || c == "\r") { malformed = true; return (result, false) }
      position += 1
      if c == "\\" {
        if let escaped = escape(template: template) { result += escaped }
        else { malformed = true; valid = false }
      } else { result += units(c.value) }
    }
    malformed = true
    return (result, false)
  }

  private mutating func template(depth: Int) {
    position += 1
    emit(.punctuation, "`")
    var result: [UInt16] = []
    var valid = true
    while let c = scalar(), !truncated {
      if c == "`" || starts("${") {
        emit(valid ? .quasi(result) : .invalid)
        result = []
        if c == "`" {
          position += 1
          emit(.punctuation, "`end")
          return
        }
        position += 2
        emit(.punctuation, "${")
        expectsOperand = true
        scan(interpolation: true, depth: depth)
      } else {
        position += 1
        if c == "\\" {
          if let escaped = escape(template: true) { result += escaped }
          else { malformed = true; valid = false }
        } else if c == "\r" {
          if scalar() == "\n" { position += 1 }
          result.append(10)
        } else { result += units(c.value) }
      }
    }
    if !truncated { malformed = true; emit(.invalid) }
  }

  private mutating func number() {
    let start = position
    var radix = 10
    if starts("0x") || starts("0X") { radix = 16; position += 2 }
    else if starts("0o") || starts("0O") { radix = 8; position += 2 }
    else if starts("0b") || starts("0B") { radix = 2; position += 2 }
    let digitsStart = position
    var valid = true
    var previousSeparator = true
    var digitCount = 0
    while let c = scalar() {
      if c == "_" {
        if previousSeparator { valid = false }
        previousSeparator = true
        position += 1
      } else if let d = digit(c), d < radix {
        previousSeparator = false
        digitCount += 1
        position += 1
      } else { break }
    }
    if previousSeparator && digitCount > 0 { valid = false }
    if radix == 10 {
      if scalar() == "." {
        position += 1
        if scalar() == "_" { valid = false }
        while let c = scalar(), (48...57).contains(c.value) || c == "_" { position += 1 }
      }
      if scalar() == "e" || scalar() == "E" {
        position += 1
        if scalar() == "+" || scalar() == "-" { position += 1 }
        let exponent = position
        if scalar() == "_" { valid = false }
        while let c = scalar(), (48...57).contains(c.value) || c == "_" { position += 1 }
        if position == exponent { valid = false }
      }
    }
    let end = position
    let bigint = scalar() == "n"
    if bigint { position += 1 }
    let raw = String(String.UnicodeScalarView(input[start..<end]))
    if raw.contains("__") || raw.last == "_" || raw.contains("_e") || raw.contains("_E") || raw.contains("._") || raw.contains("_.") || raw.contains("e_") || raw.contains("E_") { valid = false }
    let clean = raw.filter { $0 != "_" }
    if radix == 10, raw.contains("_"), clean.count > 1, clean.first == "0",
      clean.dropFirst().first.map({ $0.isNumber }) == true { valid = false }
    var value: Double?
    if radix == 10 {
      if clean.count > 1 && clean.first == "0" && clean.allSatisfy({ "01234567".contains($0) }) {
        var n: Double = 0
        for c in clean.utf8 { n = n * 8 + Double(c - 48) }
        value = n
      } else { value = Double(clean) }
    } else {
      var n: Double = 0
      for c in input[digitsStart..<end] where c != "_" {
        if let d = digit(c) { n = n * Double(radix) + Double(d) }
      }
      value = digitCount > 0 ? n : nil
    }
    if let c = scalar(), isWord(c) || (48...57).contains(c.value) { valid = false }
    if !valid || value == nil { malformed = true }
    // BigInts are lexed but deliberately outside the number folder.
    emit(valid && !bigint && value != nil ? .number(value!) : .invalid)
  }

  private mutating func regex() {
    position += 1
    var inClass = false
    while let c = scalar() {
      if isLine(c) { malformed = true; emit(.invalid); return }
      position += 1
      if c == "\\" {
        guard let next = scalar(), !isLine(next) else { malformed = true; emit(.invalid); return }
        position += 1
      } else if c == "[" { inClass = true }
      else if c == "]" { inClass = false }
      else if c == "/" && !inClass {
        while let c = scalar(), isWord(c) { position += 1 }
        emit(.regex)
        return
      }
    }
    malformed = true
    emit(.invalid)
  }
}
