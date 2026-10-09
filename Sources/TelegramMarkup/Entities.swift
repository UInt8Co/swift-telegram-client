import TelegramSchema

extension Writer {
  private struct Span {
    var start: Int
    var end: Int
    var open: String
    var close: String
  }

  /// Entities may overlap without nesting. Each boundary closes tags back to
  /// the longest still-active prefix and reopens the rest, so output nests.
  mutating func text(_ text: String, entities: [TL.MessageEntityType]) {
    let units = Array(text.utf16)
    func isBoundary(_ index: Int) -> Bool {
      index == units.count || !UTF16.isTrailSurrogate(units[index])
    }
    var spans: [Span] = []
    for entity in entities {
      guard let (offset, length, open, close) = tags(entity) else { continue }
      let start = Int(offset)
      let end = Int(offset) + Int(length)
      guard offset >= 0, length >= 0, end <= units.count, isBoundary(start), isBoundary(end) else {
        complete = false
        continue
      }
      if length > 0 { spans.append(.init(start: start, end: end, open: open, close: close)) }
    }
    // Stable: equal ranges keep entity order.
    let ordered = spans.enumerated().sorted {
      ($0.element.start, -$0.element.end, $0.offset) < (
        $1.element.start, -$1.element.end, $1.offset
      )
    }.map(\.element)
    var boundaries = Set([0, units.count])
    for span in ordered {
      boundaries.insert(span.start)
      boundaries.insert(span.end)
    }
    let points = boundaries.sorted()
    var stack: [Int] = []
    for (lower, upper) in zip(points, points.dropFirst()) {
      let active = ordered.indices.filter { ordered[$0].start <= lower && ordered[$0].end >= upper }
      var common = 0
      while common < stack.count, common < active.count, stack[common] == active[common] {
        common += 1
      }
      for index in stack[common...].reversed() { output += ordered[index].close }
      for index in active[common...] { output += ordered[index].open }
      stack = active
      literal(String(decoding: units[lower..<upper], as: UTF16.self))
    }
    for index in stack.reversed() { output += ordered[index].close }
  }

  /// Automatically detected entities (mentions, hashtags, URLs, commands and
  /// so on) are visible in the text itself and carry no tag.
  private func tags(_ entity: TL.MessageEntityType) -> (Int32, Int32, String, String)? {
    func simple(_ name: String, _ offset: Int32, _ length: Int32, _ attributes: [Attribute] = [])
      -> (Int32, Int32, String, String)
    {
      (offset, length, Self.openTag(name, attributes), "</\(name)>")
    }
    switch entity {
    case .messageEntityBold(let e): return simple("b", e.offset, e.length)
    case .messageEntityItalic(let e): return simple("i", e.offset, e.length)
    case .messageEntityUnderline(let e): return simple("u", e.offset, e.length)
    case .messageEntityStrike(let e): return simple("s", e.offset, e.length)
    case .messageEntitySpoiler(let e): return simple("tg-spoiler", e.offset, e.length)
    case .messageEntityCode(let e): return simple("code", e.offset, e.length)
    case .messageEntityPre(let e):
      guard !e.language.isEmpty else { return simple("pre", e.offset, e.length) }
      return (
        e.offset, e.length,
        "<pre>" + Self.openTag("code", [.init("class", "language-" + e.language)]), "</code></pre>"
      )
    case .messageEntityBlockquote(let e):
      return simple("blockquote", e.offset, e.length, e.collapsed ? [.init("expandable")] : [])
    case .messageEntityTextUrl(let e):
      return simple("a", e.offset, e.length, [.init("href", e.url)])
    case .messageEntityMentionName(let e):
      return simple("a", e.offset, e.length, [.init("href", "tg://user?id=\(e.userId)")])
    case .messageEntityCustomEmoji(let e):
      return simple(
        "tg-emoji", e.offset, e.length, packAttributes(renderer.customEmoji[e.documentId]))
    case .messageEntityDiffInsert(let e): return simple("ins", e.offset, e.length)
    case .messageEntityDiffReplace(let e): return simple("ins", e.offset, e.length)
    case .messageEntityDiffDelete(let e): return simple("del", e.offset, e.length)
    default: return nil
    }
  }
}
