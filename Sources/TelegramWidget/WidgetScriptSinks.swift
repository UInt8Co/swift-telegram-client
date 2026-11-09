/// Reads syntax and folded values together. This is a candidate inventory:
/// branches and callbacks are inspected without predicting whether they run.
struct WidgetScriptSinks: Sendable {
  var folder: WidgetConstantFolder
  let limits: WidgetInspection.Limits
  var result = WidgetScriptAnalysis()
  var attributed: Set<Int> = []
  var actions: Set<WidgetInspection.Action> = []
  struct PositionedEvent: Sendable {
    var position: Int
    var sequence: Int
    var value: WidgetScriptAnalysis.Event
  }
  var orderedEvents: [PositionedEvent] = []
  private var position = 0

  private mutating func emit(_ value: WidgetScriptAnalysis.Event) {
    if case .code(let source, _) = value, !folder.step(1 + source.utf8.count / 64) { return }
    orderedEvents.append(.init(position: position, sequence: orderedEvents.count, value: value))
  }

  init(folder: WidgetConstantFolder, limits: WidgetInspection.Limits) {
    self.folder = folder
    self.limits = limits
  }

  mutating func read(tokens: [WidgetScriptToken]) {
    features(tokens)
    for id in folder.nodes.indices {
      position = id
      switch folder.nodes[id].form {
      case .binary(let op, let left, let right) where op == "=" || op == "+=":
        if let property = property(left) {
          assignment(property.base, property.name, right, appending: op == "+=")
        }
      case .call(let callee, let arguments): call(callee, arguments)
      default: break
      }
    }
    // Only after all sinks have claimed their dependencies can we distinguish
    // a folded display value from an otherwise unproven script string.
    for id in folder.nodes.indices where !attributed.contains(id) {
      position = id
      if let value = folder.evaluate(id), let string = value.string { text(string, .scriptLiteral) }
    }
    result.isTruncated = result.isTruncated || folder.truncated
  }

  private mutating func property(_ id: Int) -> (base: Int, name: String)? {
    switch folder.nodes[id].form {
    case .member(let base, let name): return (base, name)
    case .index(let base, let key):
      if let value = folder.evaluate(key), let string = value.string { return (base, string) }
      return nil
    default: return nil
    }
  }

  private mutating func path(_ id: Int) -> [String]? {
    if let value = folder.evaluate(id), case .reference(let path) = value { return path }
    if case .name(let name) = folder.nodes[id].form,
      !folder.declarations.contains(name), !folder.invalidBindings.contains(name) { return [name] }
    return nil
  }

  private mutating func assignment(_ base: Int, _ name: String, _ value: Int, appending: Bool) {
    switch name {
    case "textContent": output(value, .textContent)
    case "innerText": output(value, .innerText)
    case "nodeValue": output(value, .nodeValue)
    case "value": output(value, .value)
    case "title", "alt", "placeholder", "ariaLabel": output(value, .setAttribute)
    case "innerHTML": output(value, .innerHTML, html: true)
    case "outerHTML": output(value, .outerHTML, html: true)
    case "href": action(path(base) == ["location"] ? .openLink : .anchor, appending ? nil : value)
    case "src": if !appending { dataURL(value) }
    default: break
    }
  }

  private mutating func call(_ callee: Int, _ args: [Int]) {
    let resolved = path(callee)
    let member = property(callee)
    let name = resolved?.last ?? member?.name
    guard let name else { return }
    if let resolved {
      switch resolved {
      case ["String", "fromCharCode"], ["String", "fromCodePoint"]: result.features.insert(.characterCodes)
      case ["atob"]: result.features.insert(.base64)
      case ["decodeURI"], ["decodeURIComponent"], ["unescape"]: result.features.insert(.uriDecoding)
      default: break
      }
    }
    let first = args.first
    let second = args.count > 1 ? args[1] : nil
    switch name {
    case "insertAdjacentText": if let second { output(second, .insertAdjacentText) }
    case "insertAdjacentHTML": if let second { output(second, .insertAdjacentHTML, html: true) }
    case "createTextNode": if let first { output(first, .createTextNode) }
    case "append", "prepend", "before", "after", "replaceChildren", "replaceWith", "appendChild", "insertBefore", "replaceChild":
      let arguments = ["appendChild", "insertBefore", "replaceChild"].contains(name) ? Array(args.prefix(1)) : args
      for argument in arguments {
        if let value = folder.evaluate(argument), case .fragment(let source) = value {
          output(source, .innerHTML, html: true)
        } else if !["appendChild", "insertBefore", "replaceChild"].contains(name) {
          if case .unary("...", let source) = folder.nodes[argument].form,
            let value = folder.evaluate(source), case .array(let values) = value {
            for value in values { if let string = value.string { text(string, .script(.append)) } }
            claim(source)
          } else if let value = folder.evaluate(argument), value.isConstant {
            if let string = value.string { text(string, .script(.append)); claim(argument) }
          } else { output(argument, .append) }
        }
      }
    case "fillText", "strokeText":
      result.features.insert([.canvas, .canvasText])
      if let first { output(first, .canvasText) }
    case "setAttribute":
      if let first, let second, let value = folder.evaluate(first), let attribute = value.string {
        switch attribute.lowercased() {
        case "title", "alt", "aria-label", "placeholder", "value", "label": output(second, .setAttribute)
        case "href": action(.anchor, second)
        case "src": dataURL(second)
        default: break
        }
      }
    case "write", "writeln":
      if resolved?.first == "document" {
        for argument in args { output(argument, .documentWrite, html: true) }
      }
    default: break
    }
    if let resolved {
      let widget = resolved.first == "TelegramWidget" || resolved.first == "Telegram"
      let bare = resolved.count == 1
      switch name {
      case "openLink" where widget || bare: action(.openLink, first)
      case "openTelegramLink" where widget || bare: action(.openTelegramLink, first)
      case "copyText" where widget || bare: action(.copyText, first)
      case "request" where widget || bare:
        result.features.insert(.requests)
        action(.request, first)
      case "sendTransaction" where widget && resolved.contains("wallet"),
        "signData" where widget && resolved.contains("wallet"):
        result.features.insert(.wallet)
        action(name == "sendTransaction" ? .walletSendTransaction : .walletSignData, first, stringOnly: true)
      case "open" where resolved == ["window", "open"]: action(.openLink, first)
      case "assign" where resolved.first == "location", "replace" where resolved.first == "location": action(.openLink, first)
      case "onEvent", "offEvent", "addEventListener":
        if let first, let event = folder.evaluate(first)?.string,
          ["publicDataChanged", "chatDataChanged"].contains(event) { result.features.insert(.readsState) }
      default: break
      }
      if ["eval", "Function", "setTimeout", "setInterval"].contains(name), resolved.count == 1 {
        let argument = name == "Function" ? args.last : first
        if name == "eval" || name == "Function" { result.features.insert(.dynamicCode) }
        if let argument, let source = folder.evaluate(argument)?.string {
          result.features.insert(.dynamicCode)
          emit(.code(source, nesting: folder.decodedDepths[argument] ?? folder.baseNesting))
          claim(argument)
        }
      }
    }
  }

  private mutating func dataURL(_ id: Int) {
    if let value = folder.evaluate(id)?.string, value.lowercased().hasPrefix("data:") {
      if !result.dataURLs.contains(value) { result.dataURLs.append(value); emit(.dataURL(value)) }
      claim(id)
    }
  }

  private mutating func action(_ kind: WidgetInspection.Action.Kind, _ id: Int?, stringOnly: Bool = false) {
    var target: String?
    if let id, let value = folder.evaluate(id), value.isConstant {
      if stringOnly { target = value.string }
      else if let units = folder.coerce(value) { target = String(decoding: units, as: UTF16.self) }
      if target != nil { claim(id) }
    }
    if target == nil { result.features.insert(.unresolvedAction) }
    let action = WidgetInspection.Action(kind: kind, target: target)
    guard !actions.contains(action) else { return }
    guard result.actions.count < max(0, limits.maximumActions) else { result.isTruncated = true; return }
    actions.insert(action)
    result.actions.append(action)
    emit(.action(action))
    // A partial URL is not a destination. Its constant pieces remain unproven
    // script literals, since the public contract has no partial-action origin.
  }

  private mutating func output(_ id: Int, _ sink: WidgetInspection.Sink, html: Bool = false) {
    var pieces: [String] = []
    var nesting = folder.baseNesting
    if let value = folder.evaluate(id), value.isConstant, let units = folder.coerce(value) {
      pieces = [String(decoding: units, as: UTF16.self)]
      nesting = folder.decodedDepths[id] ?? folder.baseNesting
      claim(id)
    } else {
      result.features.insert(.unresolvedOutput)
      let recovered = partial(id)
      pieces = recovered.pieces
      nesting = recovered.nesting
    }
    if html {
      var joined = ""
      for piece in pieces {
        if joined.utf8.count + piece.utf8.count > folder.maximumBytes { result.isTruncated = true; return }
        joined += piece
      }
      if !joined.isEmpty {
        guard folder.step(1 + joined.utf8.count / 64) else { return }
        let fragment = WidgetScriptAnalysis.HTMLFragment(html: joined, sink: sink)
        result.htmlFragments.append(fragment)
        emit(.fragment(fragment, nesting: nesting))
      }
    } else { for piece in pieces where piece != WidgetReading.hole { text(piece, .script(sink)) } }
  }

  // Only follow syntax whose content contributes to the output. Unknown
  // segments stay explicit, especially when the result will be read as HTML.
  private mutating func partial(_ root: Int) -> (pieces: [String], nesting: Int) {
    var pieces: [String] = []
    var nesting = folder.baseNesting
    var pending: [(node: Int?, literal: String?, depth: Int, transforms: [String], joined: Bool)] = [(root, nil, 0, [], false)]
    var bytes = 0
    while let (node, literal, depth, transforms, joined) = pending.popLast() {
      guard folder.step(), depth < 96 else { result.isTruncated = true; break }
      if let literal { pieces.append(literal); continue }
      guard let id = node else { pieces.append(WidgetReading.hole); continue }
      if let value = folder.evaluate(id), let units = folder.coerce(value) {
        nesting = max(nesting, folder.decodedDepths[id] ?? folder.baseNesting)
        if joined {
          switch value {
          case .null, .undefined: claim(id); continue
          default: break
          }
        }
        var string = String(decoding: units, as: UTF16.self)
        for transform in transforms {
          guard folder.step(1 + string.utf8.count / 64) else { break }
          switch transform {
          case "toUpperCase": string = string.uppercased()
          case "toLowerCase": string = string.lowercased()
          case "trim", "trimStart", "trimEnd": string = WidgetReading.trim(string)
          default: break
          }
        }
        guard string.utf8.count <= folder.maximumBytes - bytes else { result.isTruncated = true; break }
        bytes += string.utf8.count
        pieces.append(string)
        claim(id)
        continue
      }
      var children: [Int?] = []
      var childTransforms = transforms
      var childJoined = false
      switch folder.nodes[id].form {
      case .name(let name):
        if !folder.invalidBindings.contains(name), !folder.mutatedBindings.contains(name), let binding = folder.bindings[name] {
          children = [binding]
        }
      case .binary("+", let a, let b):
        if stringCoercion(a) || stringCoercion(b) { children = [a, b] }
      case .binary(let op, let a, let b) where op == "||" || op == "??":
        children = folder.evaluate(a)?.isConstant == true ? [a, nil, b] : [nil, b]
      case .conditional(_, let yes, let no): children = [nil, yes, nil, no, nil]
      case .template(let items): children = items.map { $0 }
      case .array(let items):
        childJoined = true
        for item in items {
          if !children.isEmpty { children.append(nil) }
          children.append(item)
        }
      case .unary("...", let value): children = [value]
      case .call(let callee, let args):
        if let member = property(callee), contentMethodAllowed(member.base, member.name) {
          switch member.name {
          case "join":
            var base = member.base
            var seen: Set<Int> = []
            while seen.insert(base).inserted, case .name(let name) = folder.nodes[base].form,
              !folder.invalidBindings.contains(name), !folder.mutatedBindings.contains(name), let binding = folder.bindings[name] {
              base = binding
            }
            if case .array(let items) = folder.nodes[base].form {
              var tasks: [(Int?, String?, Int, [String], Bool)] = []
              for (index, item) in items.enumerated() {
                if index > 0 {
                  if let separator = args.first { tasks.append((separator, nil, depth + 1, transforms, false)) }
                  else { tasks.append((nil, ",", depth + 1, transforms, false)) }
                }
                tasks.append((item, nil, depth + 1, transforms, true))
              }
              pending += tasks.reversed()
              continue
            }
            // An unknown receiver may contain arbitrarily many items. Keep
            // its result pieces and separator separated by unknown segments.
            pending.append((nil, nil, depth + 1, transforms, false))
            if let separator = args.first { pending.append((separator, nil, depth + 1, transforms, false)) }
            pending.append((nil, nil, depth + 1, transforms, false))
            pending.append((member.base, nil, depth + 1, transforms, true))
            continue
          case "concat":
            children = [member.base]
            let stringReceiver = folder.evaluate(member.base)?.string != nil
            for argument in args {
              if !stringReceiver { children.append(nil) }
              children.append(argument)
            }
          case "map":
            if args.count == 1, case .arrow(_, let body) = folder.nodes[args[0]].form {
              children = [nil, body, nil]
              childJoined = joined
            }
          case "trim", "trimStart", "trimEnd", "toUpperCase", "toLowerCase":
            children = [member.base]
            childTransforms = [member.name] + transforms
          case "repeat": children = [member.base, nil]
          case "padStart": children = args.dropFirst().prefix(1).map { $0 } + [nil, member.base]
          case "padEnd": children = [member.base, nil] + args.dropFirst().prefix(1).map { $0 }
          default: break
          }
        }
      default: break
      }
      if children.isEmpty { pieces.append(WidgetReading.hole) }
      else { pending += children.reversed().map { ($0, nil, depth + 1, childTransforms, childJoined) } }
    }
    if result.isTruncated { pieces.append(WidgetReading.hole) }
    return (pieces, nesting)
  }

  private func contentMethodAllowed(_ base: Int, _ method: String) -> Bool {
    if ["join", "map", "concat"].contains(method), folder.mutatedBindings.contains("Array") { return false }
    if method != "join" && method != "map", folder.mutatedBindings.contains("String") { return false }
    var current = base
    for _ in 0..<96 {
      switch folder.nodes[current].form {
      case .name(let name):
        return !folder.invalidBindings.contains(name) && !folder.mutatedBindings.contains(name)
      case .member(let parent, _), .index(let parent, _): current = parent
      case .object: return false
      default: return true
      }
    }
    return false
  }

  private mutating func stringCoercion(_ root: Int) -> Bool {
    var pending = [root]
    var seen: Set<Int> = []
    while let id = pending.popLast() {
      guard folder.step() else { return false }
      guard seen.insert(id).inserted else { continue }
      if let value = folder.evaluate(id) {
        switch value {
        case .string, .array, .object: return true
        default: break
        }
      }
      switch folder.nodes[id].form {
      case .template, .array, .object: return true
      case .binary("+", let a, let b): pending += [a, b]
      case .name(let name):
        if !folder.invalidBindings.contains(name), !folder.mutatedBindings.contains(name), let binding = folder.bindings[name] {
          pending.append(binding)
        }
      default: break
      }
    }
    return false
  }

  private mutating func claim(_ root: Int) {
    var pending = [root]
    while let id = pending.popLast() {
      guard attributed.insert(id).inserted else { continue }
      if case .index(let base, _) = folder.nodes[id].form { pending.append(base) }
      else { pending += folder.nodes[id].children }
      if case .name(let name) = folder.nodes[id].form,
        !folder.invalidBindings.contains(name), !folder.mutatedBindings.contains(name), let binding = folder.bindings[name] { pending.append(binding) }
    }
  }

  private mutating func text(_ value: String, _ origin: WidgetInspection.Origin) {
    // Bound the inventory by work; final text limits are applied in event order.
    guard folder.step(1 + value.utf8.count / 64), !WidgetReading.trim(value).isEmpty else { return }
    emit(.text(.init(value, origin: origin)))
  }

  private mutating func features(_ tokens: [WidgetScriptToken]) {
    for token in tokens {
      guard case .word = token.kind else { continue }
      switch token.text {
      case "setTimeout", "setInterval", "requestAnimationFrame": result.features.insert(.timers)
      case "eval", "Function": result.features.insert(.dynamicCode)
      case "fromCharCode", "fromCodePoint": result.features.insert(.characterCodes)
      case "atob": result.features.insert(.base64)
      case "decodeURI", "decodeURIComponent", "unescape": result.features.insert(.uriDecoding)
      case "publicData", "chatData", "publicDataChanged", "chatDataChanged": result.features.insert(.readsState)
      case "watchPublicData": result.features.insert(.watchesState)
      case "localStorage", "sessionStorage": result.features.insert(.storage)
      case "viewer", "chatType", "isForward", "isPreview": result.features.insert(.readsContext)
      case "Date": result.features.insert(.clockOrRandomness)
      case "getContext": result.features.insert(.canvas)
      default: break
      }
    }
    for id in folder.nodes.indices {
      if let property = property(id),
        ["now", "random", "getRandomValues", "randomUUID"].contains(property.name),
        case .name(let base) = folder.nodes[property.base].form,
        ["performance", "Math", "crypto"].contains(base) { result.features.insert(.clockOrRandomness) }
    }
  }
}
