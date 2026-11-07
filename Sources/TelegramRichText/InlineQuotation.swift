import TelegramSchema

/// A reference-free excerpt of inline content, retaining supported formatting.
public enum InlineQuotation {
  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x2E80...0xA4CF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
        0xFE10...0xFE1F, 0xFE30...0xFE4F, 0xFF00...0xFFEF,
        0x1100...0x11FF, 0xA960...0xA97F, 0xD7B0...0xD7FF,
        0x1AFF0...0x1B16F, 0x20000...0x323AF: true
      default: false
      }
    }
  }

  /// Clips in reading order using extended grapheme clusters; negative limits
  /// act as zero. Anchors and superscript fragment links are removed. Plain
  /// text clips at whitespace or CJK boundaries; letter/number/underscore
  /// hashtag tokens within one plain-text node stay whole. Tokens split across
  /// nodes are not joined. Bold, italic, fixed, URL and superscript wrappers
  /// recurse; other constructors are kept or omitted atomically. An ellipsis
  /// is appended outside the budget when content is cut.
  public static func clip(_ lead: some InlineContent, limit: Int) -> Inline {
    var budget = max(0, limit), truncated = false
    func clip(_ text: TL.RichTextType) -> TL.RichTextType? {
      if truncated { return nil }
      func nested(_ inner: TL.RichTextType, _ wrap: (TL.RichTextType) -> TL.RichTextType) -> TL.RichTextType? {
        clip(inner).map(wrap)
      }
      switch text {
      case .textEmpty: return text
      case .textAnchor: return nil
      case .textPlain(let value):
        let characters = Array(value.text)
        if characters.count <= budget { budget -= characters.count; return text }
        // CJK boundaries are word opportunities, even after an early
        // Latin-space prefix. Hashtag tokens remain indivisible.
        var end = budget
        func hashtagCharacter(_ c: Character) -> Bool {
          c.isLetter || c.isNumber || c == "_"
        }
        if end > 0, hashtagCharacter(characters[end]) {
          var start = end
          while start > 0, hashtagCharacter(characters[start - 1]) { start -= 1 }
          if start > 0, characters[start - 1] == "#" { end = start - 1 }
        }
        if end == budget {
          while end > 0, !characters[end].isWhitespace, !characters[end - 1].isWhitespace,
             !isCJK(characters[end]), !isCJK(characters[end - 1]) { end -= 1 }
        }
        var kept = characters[..<end]
        truncated = true
        while kept.last?.isWhitespace == true { kept = kept.dropLast() }
        return kept.isEmpty ? nil : .textPlain(.init(text: String(kept)))
      case .textConcat(let value):
        let texts = value.texts.compactMap(clip)
        return texts.isEmpty ? nil : .textConcat(.init(texts: texts))
      case .textSuperscript(let value):
        if case .textUrl(let link) = value.text, link.url.hasPrefix("#") { return nil }
        return nested(value.text) { .textSuperscript(.init(text: $0)) }
      case .textBold(let value): return nested(value.text) { .textBold(.init(text: $0)) }
      case .textItalic(let value): return nested(value.text) { .textItalic(.init(text: $0)) }
      case .textFixed(let value): return nested(value.text) { .textFixed(.init(text: $0)) }
      case .textUrl(var value):
        guard let inner = clip(value.text) else { return nil }
        value.text = inner
        return .textUrl(value)
      default:
        let length = RichMessage.plainText(text).count
        guard length <= budget else { truncated = true; return nil }
        budget -= length
        return text
      }
    }
    let clipped = clip(lead.richText) ?? .textEmpty(.init())
    return truncated ? Inline { Inline(richText: clipped); Text("…") } : Inline(richText: clipped)
  }
}
