// A tokenizer rather than an HTML5 tree builder. Raw text is kept separate so
// angle brackets in scripts and CSS can never become document tags.
struct WidgetHTMLReader: Sendable {
  struct Attribute: Sendable {
    var name: String
    var value: String
  }
  struct Tag: Sendable {
    var name: String
    var attributes: [Attribute]
    var selfClosing: Bool
    func value(_ name: String) -> String? { attributes.first { $0.name == name }?.value }
  }
  enum Token: Sendable {
    case start(Tag), end(String), text(String), raw(String, String)
  }
  var tokens: [Token] = []
  var malformed = false

  static let voids: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
  ]
  static let blocks: Set<String> = [
    "address", "article", "aside", "blockquote", "body", "br", "caption", "dd", "details", "dialog",
    "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
    "h5", "h6", "header", "hgroup", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary",
    "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul", "textarea", "title",
  ]

  init(_ html: String) {
    let s = Array(html.unicodeScalars)
    let lower = s.map(WidgetReading.asciiLower)
    var i = 0
    func matches(_ text: String, at index: Int) -> Bool {
      let target = Array(text.unicodeScalars)
      return index + target.count <= s.count && lower[index..<(index + target.count)].elementsEqual(target)
    }
    func nameCharacter(_ c: Unicode.Scalar) -> Bool {
      !WidgetReading.space(c) && c != ">" && c != "/" && c != "=" && c != "<" && c != "\"" && c != "'"
    }
    while i < s.count {
      if s[i] != "<" {
        let start = i
        while i < s.count, s[i] != "<" { i += 1 }
        tokens.append(.text(WidgetReading.referencesDecoded(WidgetReading.string(s[start..<i]))))
        continue
      }
      if matches("<!--", at: i) {
        i += 4
        while i < s.count, !matches("-->", at: i) { i += 1 }
        if i == s.count { malformed = true } else { i += 3 }
        continue
      }
      if matches("<!", at: i) || matches("<?", at: i) {
        i += 2
        var quote: Unicode.Scalar?
        var ended = false
        while i < s.count {
          let c = s[i]; i += 1
          if let q = quote { if c == q { quote = nil } }
          else if c == "\"" || c == "'" { quote = c }
          else if c == ">" { ended = true; break }
        }
        if !ended { malformed = true }
        continue
      }
      let beginning = i
      i += 1
      let closing = i < s.count && s[i] == "/"
      if closing { i += 1 }
      let start = i
      // A tag starts with an ASCII letter. Other '<' characters are text.
      guard i < s.count, (lower[i].value >= 97 && lower[i].value <= 122) else {
        malformed = true
        tokens.append(.text("<"))
        i = beginning + 1
        continue
      }
      while i < s.count, nameCharacter(s[i]) { i += 1 }
      let name = WidgetReading.string(lower[start..<i])
      var attributes: [Attribute] = []
      var selfClosing = false
      var ended = false
      while i < s.count {
        while i < s.count, WidgetReading.space(s[i]) { i += 1 }
        guard i < s.count else { break }
        if s[i] == ">" { i += 1; ended = true; break }
        if s[i] == "/", i + 1 < s.count, s[i + 1] == ">" {
          i += 2; selfClosing = true; ended = true; break
        }
        let attributeStart = i
        while i < s.count, nameCharacter(s[i]) { i += 1 }
        if i == attributeStart { malformed = true; i += 1; continue }
        let attributeName = WidgetReading.string(lower[attributeStart..<i])
        while i < s.count, WidgetReading.space(s[i]) { i += 1 }
        var value = ""
        if i < s.count, s[i] == "=" {
          i += 1
          while i < s.count, WidgetReading.space(s[i]) { i += 1 }
          if i < s.count, s[i] == "\"" || s[i] == "'" {
            let quote = s[i]; i += 1
            let valueStart = i
            while i < s.count, s[i] != quote { i += 1 }
            value = WidgetReading.string(s[valueStart..<i])
            if i < s.count { i += 1 } else { malformed = true }
          } else {
            let valueStart = i
            while i < s.count, !WidgetReading.space(s[i]), s[i] != ">" { i += 1 }
            value = WidgetReading.string(s[valueStart..<i])
            if valueStart == i { malformed = true }
          }
        }
        if !attributes.contains(where: { $0.name == attributeName }) {
          attributes.append(.init(name: attributeName, value: WidgetReading.referencesDecoded(value)))
        }
      }
      if !ended { malformed = true }
      if closing { tokens.append(.end(name)); continue }
      tokens.append(.start(Tag(name: name, attributes: attributes, selfClosing: selfClosing)))
      if ["script", "style", "textarea", "title", "noscript"].contains(name), !selfClosing {
        let rawStart = i
        while i < s.count {
          if matches("</" + name, at: i) {
            let after = i + 2 + name.utf8.count
            if after == s.count || WidgetReading.space(s[after]) || s[after] == ">" || s[after] == "/" { break }
          }
          i += 1
        }
        var raw = WidgetReading.string(s[rawStart..<i])
        if name == "textarea" || name == "title" { raw = WidgetReading.referencesDecoded(raw) }
        tokens.append(.raw(name, raw))
        if i == s.count { malformed = true }
      }
    }
  }
}
