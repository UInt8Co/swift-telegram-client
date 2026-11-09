/// Only these values can be folded. References describe recognized APIs;
/// neither references nor fragments are treated as constant output values.
indirect enum WidgetScriptValue: Sendable {
  case string([UInt16]), number(Double), boolean(Bool), null, undefined
  case array([WidgetScriptValue]), object([String: WidgetScriptValue])
  case reference([String]), fragment(Int)

  var isConstant: Bool {
    switch self {
    case .reference, .fragment: false
    default: true
    }
  }

  var string: String? {
    if case .string(let units) = self { return String(decoding: units, as: UTF16.self) }
    return nil
  }

  var units: [UInt16]? {
    switch self {
    case .string(let value): value
    case .number(let value): Array(Self.numberText(value).utf16)
    case .boolean(let value): Array((value ? "true" : "false").utf16)
    case .null: Array("null".utf16)
    case .undefined: Array("undefined".utf16)
    // Composite coercion is done by the bounded folder.
    default: nil
    }
  }

  static func numberText(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value == .infinity { return "Infinity" }
    if value == -.infinity { return "-Infinity" }
    if value == 0 { return "0" }
    let negative = value < 0
    let raw = String(value.magnitude).lowercased()
    let parts = raw.split(separator: "e")
    let mantissa = String(parts[0])
    let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
    let decimal = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
    var digits = mantissa.filter { $0 != "." }
    var point = decimal + exponent
    while digits.first == "0" { digits.removeFirst(); point -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let sign = negative ? "-" : ""
    if value.magnitude >= 1e-6 && value.magnitude < 1e21 {
      if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
      if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
      let i = digits.index(digits.startIndex, offsetBy: point)
      return sign + digits[..<i] + "." + digits[i...]
    }
    let rest = digits.dropFirst()
    let e = point - 1
    return sign + String(digits.prefix(1)) + (rest.isEmpty ? "" : "." + rest)
      + "e" + (e >= 0 ? "+" : "") + String(e)
  }
}

struct WidgetConstantFolder: Sendable {
  let nodes: [WidgetScriptNode]
  let bindings: [String: Int]
  let invalidBindings: Set<String>
  let mutatedBindings: Set<String>
  let declarations: Set<String>
  let maximumBytes: Int
  let maximumItems: Int
  var remaining: Int
  var truncated = false
  var cache: [Int: WidgetScriptValue] = [:]
  var unknown: Set<Int> = []
  private var evaluating: Set<Int> = []

  init(_ syntax: WidgetScriptSyntax, steps: Int, limits: WidgetInspection.Limits) {
    nodes = syntax.nodes
    bindings = syntax.bindings
    invalidBindings = syntax.invalidBindings
    mutatedBindings = syntax.mutatedBindings
    declarations = syntax.declarations
    remaining = max(0, steps)
    maximumBytes = min(max(0, limits.maximumTextBytes), 131_072) * 8
    maximumItems = min(4_096, max(0, maximumBytes))
  }

  @discardableResult mutating func step(_ count: Int = 1) -> Bool {
    guard remaining >= count else { remaining = 0; truncated = true; return false }
    remaining -= count
    return true
  }

  mutating func evaluate(_ id: Int, locals: [String: WidgetScriptValue] = [:], depth: Int = 0) -> WidgetScriptValue? {
    guard depth < 96 else { truncated = true; return nil }
    if locals.isEmpty {
      if let value = cache[id] { return value }
      if unknown.contains(id) { return nil }
    }
    guard step(), evaluating.insert(id).inserted else { return nil }
    let value = evaluateForm(id, locals: locals, depth: depth)
    evaluating.remove(id)
    let checked = value.flatMap { bounded($0) ? $0 : nil }
    if locals.isEmpty {
      if let checked { cache[id] = checked } else { unknown.insert(id) }
    }
    return checked
  }

  private mutating func evaluateForm(_ id: Int, locals: [String: WidgetScriptValue], depth: Int) -> WidgetScriptValue? {
    let next = depth + 1
    switch nodes[id].form {
    case .literal(let value): return value
    case .name(let name):
      if let value = locals[name] { return value }
      guard !invalidBindings.contains(name) else { return nil }
      if let binding = bindings[name] {
        guard let value = evaluate(binding, depth: next) else { return nil }
        return mutatedBindings.contains(name) && value.isConstant ? nil : value
      }
      guard !declarations.contains(name) else { return nil }
      if mutatedBindings.contains(name), ["String", "JSON", "atob", "decodeURI", "decodeURIComponent", "unescape"].contains(name) { return nil }
      switch name {
      case "undefined": return .undefined
      case "NaN": return .number(.nan)
      case "Infinity": return .number(.infinity)
      case "window", "document", "TelegramWidget", "Telegram", "location", "String", "JSON", "DOMParser", "atob", "decodeURI", "decodeURIComponent", "unescape", "eval", "Function", "setTimeout", "setInterval", "requestAnimationFrame":
        return .reference([name])
      default: return nil
      }
    case .member(let base, let key):
      guard let value = evaluate(base, locals: locals, depth: next) else { return nil }
      return member(value, key)
    case .index(let base, let key):
      guard let value = evaluate(base, locals: locals, depth: next),
        let property = evaluate(key, locals: locals, depth: next), let units = coerce(property) else { return nil }
      return member(value, String(decoding: units, as: UTF16.self))
    case .unary(let op, let child):
      guard let value = evaluate(child, locals: locals, depth: next) else { return nil }
      if op == "..." { return value }
      guard case .number(let number) = value else { return nil }
      switch op {
      case "+": return .number(number)
      case "-": return .number(-number)
      case "~": return .number(Double(~int32(number)))
      default: return nil
      }
    case .binary(let op, let a, let b):
      guard let a = evaluate(a, locals: locals, depth: next), let b = evaluate(b, locals: locals, depth: next) else { return nil }
      return binary(op, a, b)
    case .array(let items):
      guard items.count <= maximumItems else { truncated = true; return nil }
      var result: [WidgetScriptValue] = []
      for item in items {
        guard let value = evaluate(item, locals: locals, depth: next), value.isConstant else { return nil }
        if case .unary("...", _) = nodes[item].form {
          guard case .array(let values) = value, result.count + values.count <= maximumItems else { truncated = true; return nil }
          result += values
        } else { result.append(value) }
      }
      return .array(result)
    case .object(let items):
      guard items.count <= maximumItems else { truncated = true; return nil }
      var result: [String: WidgetScriptValue] = [:]
      for (key, item) in items {
        guard let value = evaluate(item, locals: locals, depth: next), value.isConstant else { return nil }
        result[key] = value
      }
      return .object(result)
    case .template(let items):
      var result: [UInt16] = []
      for item in items {
        guard let value = evaluate(item, locals: locals, depth: next), let units = coerce(value), append(units, to: &result) else { return nil }
      }
      return .string(result)
    case .call(let callee, let arguments):
      if case .member(let base, "map") = nodes[callee].form, arguments.count == 1,
        case .arrow(let name, let body) = nodes[arguments[0]].form,
        let value = evaluate(base, locals: locals, depth: next), case .array(let array) = value {
        var result: [WidgetScriptValue] = []
        for item in array {
          var scope = locals
          scope[name] = item
          guard let output = evaluate(body, locals: scope, depth: next), output.isConstant else { return nil }
          result.append(output)
        }
        return .array(result)
      }
      // DOM parsing is retained as syntax until an insertion consumes it.
      if case .member(let base, let method) = nodes[callee].form, let first = arguments.first {
        if method == "createContextualFragment" { return .fragment(first) }
        if method == "parseFromString", let receiver = evaluate(base, locals: locals, depth: next),
          case .reference(["DOMParserInstance"]) = receiver { return .fragment(first) }
      }
      var args: [WidgetScriptValue] = []
      for argument in arguments {
        guard let value = evaluate(argument, locals: locals, depth: next) else { return nil }
        if case .unary("...", _) = nodes[argument].form {
          guard case .array(let array) = value, args.count + array.count <= maximumItems else { return nil }
          args += array
        } else { args.append(value) }
      }
      if case .member(let base, let method) = nodes[callee].form,
        let value = evaluate(base, locals: locals, depth: next), value.isConstant {
        return methodCall(value, method, args)
      }
      if case .index(let base, let key) = nodes[callee].form,
        let method = evaluate(key, locals: locals, depth: next)?.string,
        let value = evaluate(base, locals: locals, depth: next), value.isConstant {
        return methodCall(value, method, args)
      }
      if let callable = evaluate(callee, locals: locals, depth: next), case .reference(let path) = callable {
        return globalCall(path, args)
      }
      return nil
    case .arrow, .unknown: return nil
    }
  }

  mutating func bounded(_ value: WidgetScriptValue) -> Bool {
    var pending = [value]
    var items = 0
    var bytes = 0
    while let next = pending.popLast() {
      items += 1
      if items > maximumItems + 1 { truncated = true; return false }
      switch next {
      case .string(let units):
        if units.count > maximumBytes { truncated = true; return false }
        bytes += String(decoding: units, as: UTF16.self).utf8.count
      case .array(let array): pending += array
      case .object(let object):
        bytes += object.keys.reduce(0) { $0 + $1.utf8.count }
        pending += object.values
      default: break
      }
      if bytes > maximumBytes { truncated = true; return false }
    }
    return true
  }

  mutating func append(_ value: [UInt16], to output: inout [UInt16]) -> Bool {
    guard value.count <= maximumBytes - output.count else { truncated = true; return false }
    output += value
    return true
  }

  mutating func coerce(_ value: WidgetScriptValue) -> [UInt16]? {
    if let units = value.units { return units }
    switch value {
    case .array(let values): return join(values, separator: [44])
    case .object(let object):
      guard object["toString"] == nil && object["valueOf"] == nil else { return nil }
      return Array("[object Object]".utf16)
    default: return nil
    }
  }

  mutating func join(_ values: [WidgetScriptValue], separator: [UInt16]) -> [UInt16]? {
    var result: [UInt16] = []
    for (index, value) in values.enumerated() {
      guard step() else { return nil }
      if index > 0 && !append(separator, to: &result) { return nil }
      switch value {
      case .null, .undefined: break
      default:
        guard let units = coerce(value), append(units, to: &result) else { return nil }
      }
    }
    return result
  }

  func member(_ value: WidgetScriptValue, _ key: String) -> WidgetScriptValue? {
    switch value {
    case .reference(let path):
      if path == ["window"] && ["document", "TelegramWidget", "Telegram", "location", "String", "JSON", "atob", "decodeURI", "decodeURIComponent", "unescape", "eval", "Function", "setTimeout", "setInterval"].contains(key) {
        return .reference([key])
      }
      return .reference(path + [key])
    case .fragment(let source):
      return ["body", "documentElement", "firstChild"].contains(key) ? .fragment(source) : nil
    case .object(let values):
      if let value = values[key] { return value }
      // Missing inherited properties are not necessarily undefined.
      if ["constructor", "__proto__", "toString", "valueOf", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "toLocaleString"].contains(key) { return nil }
      return .undefined
    case .array(let values):
      if key == "length" { return .number(Double(values.count)) }
      guard let index = Int(key), String(index) == key, index >= 0 else { return nil }
      return index < values.count ? values[index] : .undefined
    case .string(let value):
      if key == "length" { return .number(Double(value.count)) }
      guard let index = Int(key), String(index) == key, index >= 0 else { return nil }
      return index < value.count ? .string([value[index]]) : .undefined
    default: return nil
    }
  }

  func int32(_ number: Double) -> Int32 {
    guard number.isFinite && number != 0 else { return 0 }
    let remainder = number.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296)
    return Int32(bitPattern: UInt32(remainder < 0 ? remainder + 4_294_967_296 : remainder))
  }

  private mutating func binary(_ op: String, _ a: WidgetScriptValue, _ b: WidgetScriptValue) -> WidgetScriptValue? {
    if op == "+" {
      // Arrays and plain objects first become strings in JavaScript's +.
      let ap: WidgetScriptValue
      let bp: WidgetScriptValue
      switch a {
      case .array, .object: guard let units = coerce(a) else { return nil }; ap = .string(units)
      default: ap = a
      }
      switch b {
      case .array, .object: guard let units = coerce(b) else { return nil }; bp = .string(units)
      default: bp = b
      }
      if case .string = ap {
        guard var units = coerce(ap), let other = coerce(bp), append(other, to: &units) else { return nil }
        return .string(units)
      }
      if case .string = bp {
        guard var units = coerce(ap), let other = coerce(bp), append(other, to: &units) else { return nil }
        return .string(units)
      }
      func number(_ value: WidgetScriptValue) -> Double? {
        switch value {
        case .number(let n): n
        case .boolean(let b): b ? 1 : 0
        case .null: 0
        case .undefined: .nan
        default: nil
        }
      }
      guard let x = number(ap), let y = number(bp) else { return nil }
      return .number(x + y)
    }
    guard case .number(let x) = a, case .number(let y) = b else { return nil }
    let shift = UInt32(bitPattern: int32(y)) & 31
    switch op {
    case "-": return .number(x - y)
    case "*": return .number(x * y)
    case "/": return .number(x / y)
    case "%": return .number(x.truncatingRemainder(dividingBy: y))
    case "^": return .number(Double(int32(x) ^ int32(y)))
    case "|": return .number(Double(int32(x) | int32(y)))
    case "&": return .number(Double(int32(x) & int32(y)))
    case "<<": return .number(Double(int32(x) &<< shift))
    case ">>": return .number(Double(int32(x) &>> shift))
    case ">>>": return .number(Double(UInt32(bitPattern: int32(x)) &>> shift))
    default: return nil
    }
  }
}
