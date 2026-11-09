/// An arena keeps deeply nested input from becoming a recursive Swift value.
struct WidgetScriptNode: Sendable {
  enum Form: Sendable {
    case literal(WidgetScriptValue)
    case name(String)
    case member(Int, String)
    case index(Int, Int)
    case unary(String, Int)
    case binary(String, Int, Int)
    case array([Int])
    case object([(String, Int)])
    case template([Int])
    case call(Int, [Int])
    case arrow(String, Int)
    case conditional(Int, Int, Int)
    case unknown([Int])
  }
  var form: Form
  var children: [Int] {
    switch form {
    case .literal, .name: []
    case .conditional(let condition, let yes, let no): [condition, yes, no]
    case .member(let base, _), .unary(_, let base), .arrow(_, let base): [base]
    case .index(let a, let b), .binary(_, let a, let b): [a, b]
    case .array(let items), .template(let items), .unknown(let items): items
    case .object(let items): items.map(\.1)
    case .call(let callee, let args): [callee] + args
    }
  }
}

/// The parser recognizes expression structure, not JavaScript execution or
/// control flow. Unsupported expressions retain their children for recovery.
struct WidgetScriptSyntax: Sendable {
  let tokens: [WidgetScriptToken]
  var position = 0
  var nodes: [WidgetScriptNode] = []
  var bindings: [String: Int] = [:]
  var declarations: Set<String> = []
  var invalidBindings: Set<String> = []
  var mutatedBindings: Set<String> = []
  var malformed = false
  var truncated = false
  private var depth = 0

  init(_ tokens: [WidgetScriptToken], incomplete: Bool = false) {
    self.tokens = incomplete ? tokens + [.init(kind: .invalid, text: "<truncated>")] : tokens
  }

  func symbol(_ offset: Int = 0) -> String {
    let i = position + offset
    return i < tokens.count ? tokens[i].text : ""
  }

  mutating func add(_ form: WidgetScriptNode.Form) -> Int {
    nodes.append(.init(form: form))
    return nodes.count - 1
  }

  @discardableResult mutating func take(_ text: String) -> Bool {
    if symbol() == text && position < tokens.count { position += 1; return true }
    return false
  }

  mutating func require(_ text: String) {
    if !take(text) { malformed = true }
  }

  mutating func read() {
    _ = statements(untilBrace: false)
    // A whole-script write inventory is intentionally conservative about
    // scopes: a repeated declaration or parameter shadows the name everywhere.
    for id in nodes.indices {
      switch nodes[id].form {
      case .binary(let op, let left, _) where Self.assignments.contains(op):
        markWrite(left)
      case .unary(let op, let value) where ["++", "--", "delete"].contains(op):
        if let root = rootName(value) {
          if case .name = nodes[value].form { invalidBindings.insert(root) }
          else { mutatedBindings.insert(root) }
        }
      case .call(let callee, _):
        let property: (Int, String)?
        switch nodes[callee].form {
        case .member(let base, let name): property = (base, name)
        case .index(let base, let key):
          if case .literal(let value) = nodes[key].form, let name = value.string { property = (base, name) }
          else {
            if let root = rootName(base) { mutatedBindings.insert(root) }
            property = nil
          }
        default: property = nil
        }
        if let (base, method) = property,
          ["push", "pop", "shift", "unshift", "splice", "sort", "reverse", "fill", "copyWithin"].contains(method),
          let root = rootName(base) {
          mutatedBindings.insert(root)
        }
      default: break
      }
    }
    // Loop headers and catch parameters are bindings too, even when the
    // surrounding statement is outside the expression grammar.
    for index in tokens.indices where ["for", "catch"].contains(tokens[index].text) {
      guard index + 1 < tokens.count, tokens[index + 1].text == "(" else { continue }
      var cursor = index + 2
      var names: [String] = []
      let end = min(tokens.count, cursor + 256)
      while cursor < end && ![";", ")", "="].contains(tokens[cursor].text) {
        let token = tokens[cursor]
        if ["of", "in"].contains(token.text) {
          invalidBindings.formUnion(names)
          break
        }
        if case .word = token.kind, !["let", "const", "var"].contains(token.text) { names.append(token.text) }
        cursor += 1
      }
      if cursor == end && end < tokens.count {
        truncated = true
        invalidBindings.formUnion(declarations)
      }
      if tokens[index].text == "catch" { invalidBindings.formUnion(names) }
    }
    // Propagate object mutation through simple aliases in both directions.
    var links: [String: [String]] = [:]
    for (name, id) in bindings {
      if let other = rootName(id) {
        links[name, default: []].append(other)
        links[other, default: []].append(name)
      }
    }
    var pending = Array(mutatedBindings)
    while let name = pending.popLast() {
      for other in links[name, default: []] where mutatedBindings.insert(other).inserted { pending.append(other) }
    }
  }

  private mutating func markWrite(_ root: Int) {
    var pending = [root]
    while let id = pending.popLast() {
      switch nodes[id].form {
      case .name(let name): invalidBindings.insert(name)
      case .member, .index:
        if let name = rootName(id) { mutatedBindings.insert(name) }
      case .array, .object, .unknown: pending += nodes[id].children
      default: break
      }
    }
  }

  func rootName(_ id: Int) -> String? {
    var current = id
    for _ in 0..<96 {
      switch nodes[current].form {
      case .name(let name): return name
      case .member(let base, _), .index(let base, _): current = base
      default: return nil
      }
    }
    return nil
  }

  private mutating func statements(untilBrace: Bool) -> [Int] {
    var roots: [Int] = []
    while position < tokens.count && !truncated {
      if untilBrace && take("}") { return roots }
      let start = position
      if ["const", "let", "var"].contains(symbol()) {
        position += 1
        declaration()
      } else if take("{") {
        if depth >= 96 { truncated = true; break }
        depth += 1
        roots += statements(untilBrace: true)
        depth -= 1
      } else if ["return", "throw", "else", "export", "default"].contains(symbol()) {
        position += 1
      } else if let id = expression() { roots.append(id) }
      if position == start { position += 1 }
    }
    if untilBrace && !truncated { malformed = true }
    return roots
  }

  private mutating func register(_ name: String, _ id: Int?) {
    if !declarations.insert(name).inserted { invalidBindings.insert(name) }
    if let id { bindings[name] = id }
  }

  private mutating func declaration() {
    repeat {
      if take("{") {
        var names: [(String, String)] = []
        while position < tokens.count && symbol() != "}" {
          guard case .word = tokens[position].kind else { break }
          let key = symbol()
          position += 1
          var name = key
          if take(":") { name = symbol(); position += position < tokens.count ? 1 : 0 }
          names.append((key, name))
          if !take(",") { break }
        }
        require("}")
        let value = take("=") ? expression() : nil
        for (key, name) in names { register(name, value.map { add(.member($0, key)) }) }
      } else if take("[") {
        var names: [(Int, String)] = []
        var index = 0
        while position < tokens.count && symbol() != "]" {
          if take(",") { index += 1; continue }
          guard case .word = tokens[position].kind else { break }
          names.append((index, symbol()))
          position += 1
          index += 1
          if !take(",") { break }
        }
        require("]")
        let value = take("=") ? expression() : nil
        for (index, name) in names {
          if let value {
            let key = add(.literal(.number(Double(index))))
            register(name, add(.index(value, key)))
          } else { register(name, nil) }
        }
      } else {
        guard position < tokens.count, case .word = tokens[position].kind else { return }
        let name = symbol()
        position += 1
        let value = take("=") ? expression() : nil
        register(name, value)
      }
    } while take(",")
  }

  static let assignments: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=", "??="]

  private func precedence(_ op: String) -> Int? {
    if Self.assignments.contains(op) { return 1 }
    switch op {
    case "??", "||": return 3
    case "&&": return 4
    case "|": return 5
    case "^": return 6
    case "&": return 7
    case "==", "!=", "===", "!==": return 8
    case "<", ">", "<=", ">=", "in", "instanceof": return 9
    case "<<", ">>", ">>>": return 10
    case "+", "-": return 11
    case "*", "/", "%": return 12
    case "**": return 13
    default: return nil
    }
  }

  mutating func expression(_ minimum: Int = 1) -> Int? {
    guard depth < 96 else { truncated = true; return nil }
    depth += 1
    defer { depth -= 1 }
    guard var left = primary() else { return nil }
    while position < tokens.count && !truncated {
      if take("<truncated>") {
        left = add(.unknown([left]))
        break
      }
      if take(".") || take("?.") {
        if symbol() == "(" { // Optional calls remain unknown.
          let args = arguments()
          left = add(.unknown([left] + args))
        } else if position < tokens.count, case .word = tokens[position].kind {
          let name = symbol()
          position += 1
          left = add(.member(left, name))
        } else { malformed = true; break }
      } else if take("[") {
        let key = expression() ?? add(.unknown([]))
        require("]")
        left = add(.index(left, key))
      } else if symbol() == "(" {
        let args = arguments()
        left = add(.call(left, args))
      } else if symbol() == "`" {
        let value = primary() ?? add(.unknown([]))
        left = add(.unknown([left, value]))
      } else if symbol() == "++" || symbol() == "--" {
        let op = symbol()
        position += 1
        left = add(.unary(op, left))
      } else if symbol() == "=>" && minimum <= 1 {
        position += 1
        if case .name(let name) = nodes[left].form {
          invalidBindings.insert(name)
          left = add(.arrow(name, arrowBody()))
        } else {
          if case .unknown(let parameters) = nodes[left].form {
            for parameter in parameters { markWrite(parameter) }
          }
          left = add(.unknown([left, arrowBody()]))
        }
      } else if symbol() == "?" && minimum <= 2 {
        position += 1
        let yes = expression() ?? add(.unknown([]))
        require(":")
        let no = expression(2) ?? add(.unknown([]))
        left = add(.conditional(left, yes, no))
      } else if let precedence = precedence(symbol()), precedence >= minimum {
        let op = symbol()
        position += 1
        let right = expression(precedence + (Self.assignments.contains(op) || op == "**" ? 0 : 1)) ?? add(.unknown([]))
        left = add(.binary(op, left, right))
      } else { break }
    }
    return truncated ? add(.unknown([left])) : left
  }

  private mutating func arguments() -> [Int] {
    require("(")
    var args: [Int] = []
    while position < tokens.count && symbol() != ")" && !truncated {
      let start = position
      if let arg = expression() { args.append(arg) }
      if position == start { position += 1; malformed = true }
      if !take(",") { break }
    }
    require(")")
    return args
  }

  private mutating func arrowBody() -> Int {
    if take("{") {
      if take("return") {
        let body = expression() ?? add(.unknown([]))
        _ = take(";")
        if take("}") { return body }
        return add(.unknown([body] + statements(untilBrace: true)))
      }
      return add(.unknown(statements(untilBrace: true)))
    }
    return expression() ?? add(.unknown([]))
  }

  private mutating func primary() -> Int? {
    guard position < tokens.count else { return nil }
    let token = tokens[position]
    switch token.kind {
    case .string(let value), .quasi(let value):
      position += 1
      return add(.literal(.string(value)))
    case .number(let value):
      position += 1
      return add(.literal(.number(value)))
    case .regex, .invalid:
      position += 1
      return add(.unknown([]))
    case .word:
      let name = symbol()
      position += 1
      switch name {
      case "true": return add(.literal(.boolean(true)))
      case "false": return add(.literal(.boolean(false)))
      case "null": return add(.literal(.null))
      case "undefined": return add(.name(name))
      case "const", "let", "var":
        declaration()
        return add(.unknown([]))
      case "class":
        if position < tokens.count, case .word = tokens[position].kind {
          register(symbol(), nil)
          position += 1
        }
        return add(.unknown([]))
      case "new": return expression(14)
      case "typeof", "void", "delete":
        return add(.unary(name, expression(14) ?? add(.unknown([]))))
      case "function":
        if position < tokens.count, case .word = tokens[position].kind {
          register(symbol(), nil)
          position += 1
        }
        require("(")
        var params: [String] = []
        while position < tokens.count && symbol() != ")" {
          if case .word = tokens[position].kind { params.append(symbol()); invalidBindings.insert(symbol()) }
          position += 1
        }
        require(")")
        let body = arrowBody()
        if params.count == 1 { return add(.arrow(params[0], body)) }
        return add(.unknown([body]))
      default: return add(.name(name))
      }
    case .punctuation: break
    }
    if ["+", "-", "~", "!", "...", "++", "--"].contains(symbol()) {
      let op = symbol()
      position += 1
      return add(.unary(op, expression(14) ?? add(.unknown([]))))
    }
    if take("(") {
      var values: [Int] = []
      repeat {
        if let value = expression() { values.append(value) } else { break }
      } while take(",")
      require(")")
      return values.count == 1 ? values[0] : add(.unknown(values))
    }
    if take("[") {
      var values: [Int] = []
      while position < tokens.count && symbol() != "]" && !truncated {
        if take(",") { values.append(add(.literal(.undefined))); continue }
        guard let value = expression() else { break }
        values.append(value)
        if !take(",") { break }
      }
      require("]")
      return add(.array(values))
    }
    if take("{") {
      var values: [(String, Int)] = []
      var valid = true
      while position < tokens.count && symbol() != "}" && !truncated {
        let token = tokens[position]
        let key: String
        switch token.kind {
        case .word: key = token.text
        case .string(let units):
          key = String(decoding: units, as: UTF16.self)
          _ = add(.literal(.string(units)))
        case .number(let n): key = WidgetScriptValue.numberText(n)
        default: valid = false; key = ""
        }
        position += 1
        let value: Int
        if take(":") { value = expression() ?? add(.unknown([])) }
        else { value = add(.name(key)) }
        if key == "__proto__" { valid = false }
        values.append((key, value))
        if !take(",") { break }
      }
      require("}")
      return add(valid ? .object(values) : .unknown(values.map(\.1)))
    }
    if take("`") {
      var values: [Int] = []
      while position < tokens.count && symbol() != "`end" && !truncated {
        if take("${") {
          if let value = expression() { values.append(value) }
          require("}")
        } else if let value = primary() { values.append(value) }
        else { position += 1; malformed = true }
      }
      require("`end")
      return add(.template(values))
    }
    return nil
  }
}
