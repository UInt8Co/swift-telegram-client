// Small shared operations for the static readers. No browser or script engine
// is involved; each reader makes forward progress over its input.
enum WidgetReading: Sendable {
  static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
    String(String.UnicodeScalarView(scalars))
  }

  static func space(_ c: Unicode.Scalar) -> Bool {
    c.properties.isWhitespace
  }

  static func trim(_ value: String) -> String {
    String(value.drop(while: { $0.isWhitespace }).reversed()
      .drop(while: { $0.isWhitespace }).reversed())
  }

  static func collapse(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  static func prefix(_ value: String, bytes: Int) -> String {
    var size = 0
    return String(value.prefix { character in
      let count = character.utf8.count
      guard count <= max(0, bytes) - size else { return false }
      size += count
      return true
    })
  }

  static func asciiLower(_ c: Unicode.Scalar) -> Unicode.Scalar {
    c.value >= 65 && c.value <= 90 ? Unicode.Scalar(c.value + 32)! : c
  }

  static func hex(_ c: Unicode.Scalar) -> Int? {
    switch c.value {
    case 48...57: Int(c.value - 48)
    case 65...70: Int(c.value - 55)
    case 97...102: Int(c.value - 87)
    default: nil
    }
  }

  static let references: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}",
    "copy": "©", "reg": "®", "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«",
    "raquo": "»", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "trade": "™",
    "bull": "•", "middot": "·", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    "times": "×", "divide": "÷", "plusmn": "±", "deg": "°", "micro": "µ", "para": "¶",
    "sect": "§", "acute": "´", "shy": "\u{ad}", "ensp": "\u{2002}", "emsp": "\u{2003}",
    "thinsp": "\u{2009}", "zwnj": "\u{200c}", "zwj": "\u{200d}", "lrm": "\u{200e}",
    "rlm": "\u{200f}", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
    "ne": "≠", "le": "≤", "ge": "≥", "infin": "∞", "hearts": "♥", "check": "✓",
    "NewLine": "\n", "Tab": "\t", "colon": ":", "sol": "/", "bsol": "\\", "commat": "@",
    "excl": "!", "num": "#", "percnt": "%", "equals": "=", "semi": ";", "quest": "?",
    "aacute": "á", "eacute": "é", "ouml": "ö", "uuml": "ü", "ntilde": "ñ", "szlig": "ß",
    "AMP": "&", "LT": "<", "GT": ">", "QUOT": "\"",
  ]

  static func referencesDecoded(_ value: String) -> String {
    let s = Array(value.unicodeScalars)
    var i = 0
    var output = ""
    while i < s.count {
      guard s[i] == "&" else { output.unicodeScalars.append(s[i]); i += 1; continue }
      let start = i
      i += 1
      if i < s.count, s[i] == "#" {
        i += 1
        var radix = 10
        if i < s.count, s[i] == "x" || s[i] == "X" { radix = 16; i += 1 }
        let digits = i
        var number: UInt32 = 0
        while i < s.count, let digit = hex(s[i]), digit < radix {
          number = min(0x110000, number * UInt32(radix) + UInt32(digit))
          i += 1
        }
        if i > digits {
          if i < s.count, s[i] == ";" { i += 1 }
          let scalar = number == 0 ? nil : Unicode.Scalar(number)
          output.unicodeScalars.append(scalar ?? "\u{fffd}")
          continue
        }
      } else {
        let name = i
        while i < s.count, i - name < 32,
          (s[i].value >= 65 && s[i].value <= 90) || (s[i].value >= 97 && s[i].value <= 122)
            || (s[i].value >= 48 && s[i].value <= 57)
        { i += 1 }
        if i < s.count, s[i] == ";", let replacement = references[string(s[name..<i])] {
          output += replacement
          i += 1
          continue
        }
      }
      output += "&"
      i = start + 1
    }
    return output
  }
}
