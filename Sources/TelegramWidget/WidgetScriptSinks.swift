/// Reads syntax and folded values together. This is a candidate inventory:
/// branches and callbacks are inspected without predicting whether they run.
struct WidgetScriptSinks: Sendable {
  var folder: WidgetConstantFolder
  let limits: WidgetInspection.Limits
  var result = WidgetScriptAnalysis()
  var attributed: Set<Int> = []
  var texts: Set<WidgetInspection.Text> = []
  var actions: Set<WidgetInspection.Action> = []
  var dynamicSources: [String] = []
  private var totalTextBytes = 0

  init(folder: WidgetConstantFolder, limits: WidgetInspection.Limits) {
    self.folder = folder
    self.limits = limits
  }

  mutating func read(tokens: [WidgetScriptToken]) {
    features(tokens)
    for id in folder.nodes.indices {
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
          dynamicSources.append(source)
        }
      }
    }
  }

  private mutating func dataURL(_ id: Int) {
    if let value = folder.evaluate(id)?.string, value.lowercased().hasPrefix("data:") {
      if !result.dataURLs.contains(value) { result.dataURLs.append(value) }
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
    guard actions.insert(action).inserted else { return }
    guard result.actions.count < max(0, limits.maximumActions) else { result.isTruncated = true; return }
    result.actions.append(action)
    // A partial URL is not a destination. Its constant pieces remain unproven
    // script literals, since the public contract has no partial-action origin.
  }

  private mutating func output(_ id: Int, _ sink: WidgetInspection.Sink, html: Bool = false) {
    var pieces: [String] = []
    if let value = folder.evaluate(id), value.isConstant, let units = folder.coerce(value) {
      pieces = [String(decoding: units, as: UTF16.self)]
      claim(id)
    } else {
      result.features.insert(.unresolvedOutput)
      pieces = partial(id)
    }
    if html {
      var joined = ""
      for piece in pieces {
        if joined.utf8.count + piece.utf8.count > folder.maximumBytes { result.isTruncated = true; return }
        joined += piece
      }
      if !joined.isEmpty {
        if result.htmlFragments.count >= max(0, limits.maximumTexts) { result.isTruncated = true; return }
        let fragment = WidgetScriptAnalysis.HTMLFragment(html: joined, sink: sink)
        if !result.htmlFragments.contains(fragment) { result.htmlFragments.append(fragment) }
      }
    } else { for piece in pieces { text(piece, .script(sink)) } }
  }

  private mutating func partial(_ root: Int) -> [String] {
    var result: [String] = []
    var pending = [root]
    var visited: Set<Int> = []
    while let id = pending.popLast() {
      guard visited.insert(id).inserted, folder.step() else { continue }
      if let value = folder.evaluate(id), let units = value.units {
        result.append(String(decoding: units, as: UTF16.self))
        claim(id)
      } else {
        // Resolve a constant binding's syntax too, when only part of its value
        // was recoverable (for example an array joined around runtime state).
        if case .name(let name) = folder.nodes[id].form,
          !folder.invalidBindings.contains(name), !folder.mutatedBindings.contains(name), let binding = folder.bindings[name] {
          pending.append(binding)
        } else { pending += folder.nodes[id].children.reversed() }
      }
    }
    return result
  }

  private mutating func claim(_ root: Int) {
    var pending = [root]
    while let id = pending.popLast() {
      guard attributed.insert(id).inserted else { continue }
      pending += folder.nodes[id].children
      if case .name(let name) = folder.nodes[id].form,
        !folder.invalidBindings.contains(name), !folder.mutatedBindings.contains(name), let binding = folder.bindings[name] { pending.append(binding) }
    }
  }

  private mutating func text(_ value: String, _ origin: WidgetInspection.Origin) {
    guard value.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { return }
    let candidate = WidgetInspection.Text(value, origin: origin)
    guard texts.insert(candidate).inserted else { return }
    guard result.texts.count < max(0, limits.maximumTexts) else { result.isTruncated = true; return }
    let available = min(max(0, limits.maximumTextBytes), max(0, limits.maximumTotalTextBytes) - totalTextBytes)
    var output = ""
    var bytes = 0
    for scalar in value.unicodeScalars {
      let size = scalar.utf8.count
      if bytes + size > available { result.isTruncated = true; break }
      output.unicodeScalars.append(scalar)
      bytes += size
    }
    if !output.isEmpty {
      totalTextBytes += bytes
      result.texts.append(.init(output, origin: origin))
    }
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
