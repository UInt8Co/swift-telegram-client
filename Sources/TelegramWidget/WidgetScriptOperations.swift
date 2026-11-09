#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension WidgetConstantFolder {
  private func integer(_ args: [WidgetScriptValue], _ index: Int, default fallback: Int = 0) -> Int? {
    guard index < args.count else { return fallback }
    if case .undefined = args[index] { return fallback }
    guard case .number(let number) = args[index] else { return nil }
    if number.isNaN { return 0 }
    return Int(min(Double(maximumBytes + 1), max(-Double(maximumBytes + 1), number.rounded(.towardZero))))
  }

  private func relative(_ index: Int, _ count: Int) -> Int {
    index < 0 ? max(0, count + index) : min(count, index)
  }

  mutating func methodCall(_ receiver: WidgetScriptValue, _ name: String, _ args: [WidgetScriptValue]) -> WidgetScriptValue? {
    guard step(), args.allSatisfy(\.isConstant) else { return nil }
    if case .array(let values) = receiver {
      guard !mutatedBindings.contains("Array") else { return nil }
      switch name {
      case "join":
        let separator: [UInt16]
        if args.isEmpty { separator = [44] }
        else if case .undefined = args[0] { separator = [44] }
        else { guard let units = coerce(args[0]) else { return nil }; separator = units }
        return join(values, separator: separator).map { .string($0) }
      case "reverse": return .array(values.reversed())
      case "slice":
        guard let start = integer(args, 0), let end = integer(args, 1, default: values.count) else { return nil }
        let a = relative(start, values.count)
        let b = max(a, relative(end, values.count))
        return .array(Array(values[a..<b]))
      case "at":
        guard let index = integer(args, 0) else { return nil }
        let i = index < 0 ? values.count + index : index
        return i >= 0 && i < values.count ? values[i] : .undefined
      case "concat":
        var result = values
        for arg in args {
          if case .array(let values) = arg { result += values } else { result.append(arg) }
          if result.count > maximumItems { truncated = true; return nil }
        }
        return .array(result)
      default: return nil
      }
    }
    guard case .string(let units) = receiver, !mutatedBindings.contains("String") else { return nil }
    let count = units.count
    switch name {
    case "slice", "substring", "substr":
      guard let start = integer(args, 0), let end = integer(args, 1, default: count) else { return nil }
      let a: Int
      let b: Int
      if name == "substring" {
        a = min(min(count, max(0, start)), min(count, max(0, end)))
        b = max(min(count, max(0, start)), min(count, max(0, end)))
      } else if name == "substr" {
        a = relative(start, count)
        b = min(count, a + max(0, end))
      } else {
        a = relative(start, count)
        b = max(a, relative(end, count))
      }
      return .string(Array(units[a..<b]))
    case "charAt", "charCodeAt", "codePointAt", "at":
      guard let raw = integer(args, 0) else { return nil }
      let index = name == "at" && raw < 0 ? count + raw : raw
      guard index >= 0 && index < count else {
        if name == "charAt" { return .string([]) }
        return name == "charCodeAt" ? .number(.nan) : .undefined
      }
      if name == "charAt" || name == "at" { return .string([units[index]]) }
      var code = UInt32(units[index])
      if name == "codePointAt" && (0xD800...0xDBFF).contains(code), index + 1 < count,
        (0xDC00...0xDFFF).contains(units[index + 1]) {
        code = (code - 0xD800) * 1024 + UInt32(units[index + 1]) - 0xDC00 + 0x10000
      }
      return .number(Double(code))
    case "concat":
      var result = units
      for arg in args {
        guard let next = coerce(arg), append(next, to: &result) else { return nil }
      }
      return .string(result)
    case "toUpperCase", "toLowerCase":
      // A case conversion on an unpaired surrogate must preserve that unit.
      var result: [UInt16] = []
      var run: [UInt16] = []
      func converted(_ value: [UInt16]) -> [UInt16] {
        let string = String(decoding: value, as: UTF16.self)
        return Array((name == "toUpperCase" ? string.uppercased() : string.lowercased()).utf16)
      }
      var i = 0
      while i < units.count {
        let c = units[i]
        if (0xD800...0xDBFF).contains(c), i + 1 < units.count, (0xDC00...0xDFFF).contains(units[i + 1]) {
          run += [c, units[i + 1]]; i += 2
        } else if (0xD800...0xDFFF).contains(c) {
          guard append(converted(run), to: &result), append([c], to: &result) else { return nil }
          run = []; i += 1
        } else { run.append(c); i += 1 }
      }
      guard append(converted(run), to: &result) else { return nil }
      return .string(result)
    case "trim", "trimStart", "trimEnd":
      var a = 0
      var b = count
      if name != "trimEnd" { while a < b && Self.whitespace(units[a]) { a += 1 } }
      if name != "trimStart" { while b > a && Self.whitespace(units[b - 1]) { b -= 1 } }
      return .string(Array(units[a..<b]))
    case "repeat":
      guard let times = integer(args, 0), times >= 0 else { return nil }
      guard times <= maximumBytes, units.isEmpty || times <= maximumBytes / units.count else { truncated = true; return nil }
      var result: [UInt16] = []
      for _ in 0..<times { result += units }
      return .string(result)
    case "padStart", "padEnd":
      guard let size = integer(args, 0) else { return nil }
      if size <= units.count { return receiver }
      guard size <= maximumBytes else { truncated = true; return nil }
      let padding: [UInt16]
      if args.count < 2 { padding = [32] }
      else if case .undefined = args[1] { padding = [32] }
      else { guard let value = coerce(args[1]) else { return nil }; padding = value }
      if padding.isEmpty { return receiver }
      let extra = (0..<(size - units.count)).map { padding[$0 % padding.count] }
      return .string(name == "padStart" ? extra + units : units + extra)
    case "split":
      if args.isEmpty { return .array([receiver]) }
      var requested = UInt32.max
      if args.count > 1 {
        if case .number(let n) = args[1] { requested = UInt32(bitPattern: int32(n)) }
        else if case .undefined = args[1] {} else { return nil }
      }
      let limit = Int(requested)
      if limit == 0 { return .array([]) }
      if case .undefined = args[0] { return .array([receiver]) }
      guard case .string(let separator) = args[0] else { return nil }
      let matches = Self.matches(units, separator)
      var result: [WidgetScriptValue] = []
      var start = 0
      if separator.isEmpty {
        guard min(count, limit) <= maximumItems else { truncated = true; return nil }
        return .array(units.prefix(limit).map { .string([$0]) })
      }
      for match in matches {
        if result.count == limit { return .array(result) }
        guard result.count < maximumItems else { truncated = true; return nil }
        result.append(.string(Array(units[start..<match])))
        start = match + separator.count
      }
      if result.count < limit {
        guard result.count < maximumItems else { truncated = true; return nil }
        result.append(.string(Array(units[start...])))
      }
      return .array(result)
    case "replace", "replaceAll":
      guard args.count >= 2, case .string(let pattern) = args[0], case .string(let replacement) = args[1] else { return nil }
      let matches = Self.matches(units, pattern)
      var result: [UInt16] = []
      var start = 0
      for match in name == "replace" ? Array(matches.prefix(1)) : matches {
        guard step(), append(Array(units[start..<match]), to: &result) else { return nil }
        var index = 0
        while index < replacement.count {
          var part = [replacement[index]]
          if replacement[index] == 36 && index + 1 < replacement.count {
            switch replacement[index + 1] {
            case 36: part = [36]; index += 1
            case 38: part = pattern; index += 1
            case 96: part = Array(units[..<match]); index += 1
            case 39: part = Array(units[(match + pattern.count)...]); index += 1
            default: break
            }
          }
          guard append(part, to: &result) else { return nil }
          index += 1
        }
        start = match + pattern.count
      }
      guard append(Array(units[start...]), to: &result) else { return nil }
      return .string(result)
    default: return nil
    }
  }

  private static func whitespace(_ unit: UInt16) -> Bool {
    [9, 10, 11, 12, 13, 32, 160, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF].contains(unit)
      || (0x2000...0x200A).contains(unit)
  }

  /// Linear substring matching; repeated prefixes must not make recovery
  /// quadratic in the script's string size.
  private static func matches(_ text: [UInt16], _ pattern: [UInt16]) -> [Int] {
    if pattern.isEmpty { return Array(0...text.count) }
    var table = [Int](repeating: 0, count: pattern.count)
    var length = 0
    for i in 1..<pattern.count {
      while length > 0 && pattern[i] != pattern[length] { length = table[length - 1] }
      if pattern[i] == pattern[length] { length += 1 }
      table[i] = length
    }
    var result: [Int] = []
    length = 0
    for (i, unit) in text.enumerated() {
      while length > 0 && unit != pattern[length] { length = table[length - 1] }
      if unit == pattern[length] { length += 1 }
      if length == pattern.count { result.append(i + 1 - length); length = 0 }
    }
    return result
  }

  mutating func globalCall(_ path: [String], _ args: [WidgetScriptValue]) -> WidgetScriptValue? {
    guard step() else { return nil }
    if path == ["DOMParser"] { return .reference(["DOMParserInstance"]) }
    if path.first == "document", let method = path.last,
      ["getElementById", "querySelector", "querySelectorAll", "createElement", "createElementNS", "createRange"].contains(method) {
      return .reference(["element"])
    }
    guard args.allSatisfy(\.isConstant) else { return nil }
    if path == ["String", "fromCharCode"] || path == ["String", "fromCodePoint"] {
      var result: [UInt16] = []
      for arg in args {
        guard step(), case .number(let n) = arg else { return nil }
        if path.last == "fromCharCode" { result.append(UInt16(truncatingIfNeeded: int32(n))) }
        else {
          guard n.isFinite, n.rounded(.towardZero) == n, n >= 0 && n <= 0x10FFFF else { return nil }
          let value = UInt32(n)
          if value <= 0xFFFF { result.append(UInt16(value)) }
          else { result += [UInt16(0xD800 + ((value - 0x10000) >> 10)), UInt16(0xDC00 + ((value - 0x10000) & 1023))] }
        }
        if result.count > maximumBytes { truncated = true; return nil }
      }
      return .string(result)
    }
    guard let first = args.first, case .string(let units) = first else { return nil }
    let string = String(decoding: units, as: UTF16.self)
    switch path {
    case ["atob"]:
      var encoded = string.filter { !" \t\n\r\u{0C}".contains($0) }
      if encoded.count % 4 == 0 {
        if encoded.last == "=" { encoded.removeLast() }
        if encoded.last == "=" { encoded.removeLast() }
      }
      guard encoded.count % 4 != 1, encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47 }) else { return nil }
      while encoded.count % 4 != 0 { encoded += "=" }
      guard let data = Data(base64Encoded: encoded) else { return nil }
      return .string(data.map { UInt16($0) })
    case ["decodeURI"], ["decodeURIComponent"]:
      return Self.decodeURI(units, preserveReserved: path == ["decodeURI"]).map { .string($0) }
    case ["unescape"]:
      var result: [UInt16] = []
      var index = 0
      while index < units.count {
        if units[index] == 37 {
          let unicode = index + 1 < units.count && units[index + 1] == 117
          let start = index + (unicode ? 2 : 1)
          let count = unicode ? 4 : 2
          if start + count <= units.count, let value = Self.hex(Array(units[start..<(start + count)])) {
            result.append(UInt16(value)); index = start + count; continue
          }
        }
        result.append(units[index]); index += 1
      }
      return .string(result)
    case ["JSON", "parse"]:
      do {
        let decoded = try JSONDecoder().decode(WidgetScriptJSON.self, from: Data(string.utf8))
        return decoded.value
      } catch WidgetScriptJSON.Failure.depth { truncated = true; return nil }
      catch { return nil }
    default: return nil
    }
  }

  private static func hex(_ units: [UInt16]) -> UInt32? {
    var value: UInt32 = 0
    for unit in units {
      let digit: UInt32
      switch unit {
      case 48...57: digit = UInt32(unit - 48)
      case 65...70: digit = UInt32(unit - 55)
      case 97...102: digit = UInt32(unit - 87)
      default: return nil
      }
      value = value * 16 + digit
    }
    return value
  }

  private static func decodeURI(_ units: [UInt16], preserveReserved: Bool) -> [UInt16]? {
    var result: [UInt16] = []
    var index = 0
    while index < units.count {
      if units[index] != 37 { result.append(units[index]); index += 1; continue }
      guard index + 2 < units.count, let first = hex(Array(units[(index + 1)...(index + 2)])) else { return nil }
      if first < 128 {
        if preserveReserved && Array(";/?:@&=+$,#".utf16).contains(UInt16(first)) { result += units[index...(index + 2)] }
        else { result.append(UInt16(first)) }
        index += 3
        continue
      }
      let count: Int
      switch first {
      case 0xC2...0xDF: count = 2
      case 0xE0...0xEF: count = 3
      case 0xF0...0xF4: count = 4
      default: return nil
      }
      var bytes = [UInt8(first)]
      for offset in 1..<count {
        let i = index + offset * 3
        guard i + 2 < units.count, units[i] == 37, let byte = hex(Array(units[(i + 1)...(i + 2)])) else { return nil }
        bytes.append(UInt8(byte))
      }
      guard let string = String(bytes: bytes, encoding: .utf8) else { return nil }
      result += string.utf16
      index += count * 3
    }
    return result
  }
}

private struct WidgetScriptJSON: Decodable, Sendable {
  enum Failure: Error { case depth }
  var value: WidgetScriptValue

  init(from decoder: any Decoder) throws {
    guard decoder.codingPath.count < 64 else { throw Failure.depth }
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { value = .null }
    else if let boolean = try? container.decode(Bool.self) { value = .boolean(boolean) }
    else if let string = try? container.decode(String.self) { value = .string(Array(string.utf16)) }
    else if let number = try? container.decode(Double.self) { value = .number(number) }
    else if var array = try? decoder.unkeyedContainer() {
      var values: [WidgetScriptValue] = []
      while !array.isAtEnd { values.append(try array.decode(WidgetScriptJSON.self).value) }
      value = .array(values)
    } else { value = .object(try container.decode([String: WidgetScriptJSON].self).mapValues(\.value)) }
  }
}
