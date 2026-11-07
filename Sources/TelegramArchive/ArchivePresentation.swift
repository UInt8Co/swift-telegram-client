extension TLArchive {
  /// Snapshots already contain encoded JSON. Change only whitespace outside
  /// strings, preserving exact integer/decimal tokens, escapes and every field.
  /// Uses two-space indentation, preserving key and array order. Does not validate
  /// JSON; malformed input receives best-effort whitespace formatting. Synchronous,
  /// with no task cancellation checks.
  public static func prettyPrintedJSON(_ json: String) -> String {
    var result = ""
    var depth = 0
    var quoted = false
    var escaped = false
    var previous: Unicode.Scalar?
    for scalar in json.unicodeScalars {
      if quoted {
        result.unicodeScalars.append(scalar)
        if escaped { escaped = false }
        else if scalar == "\\" { escaped = true }
        else if scalar == "\"" { quoted = false }
        continue
      }
      if scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" { continue }
      let closes = scalar == "}" || scalar == "]"
      let opened = previous == "{" || previous == "["
      if !closes && (opened || previous == ",") {
        result += "\n" + String(repeating: "  ", count: depth)
      }
      if closes {
        depth = max(0, depth - 1)
        if !opened { result += "\n" + String(repeating: "  ", count: depth) }
      }
      result.unicodeScalars.append(scalar)
      if scalar == ":" { result += " " }
      else if scalar == "{" || scalar == "[" { depth += 1 }
      else if scalar == "\"" { quoted = true }
      previous = scalar
    }
    return result
  }

}
