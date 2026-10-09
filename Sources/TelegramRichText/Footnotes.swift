import TelegramSchema

/// TDLib represents richTextReference as textAnchor, and richTextReferenceLink
/// as textUrl with a #name target. Keep definitions out of the paragraph body.
enum Footnotes {
  static func resolve(in blocks: [TL.PageBlockType], sectionTitle: String? = nil) -> [TL
    .PageBlockType]
  {
    var names: [String] = []
    var definitions: [String: TL.RichTextType] = [:]
    // Only '*' markers emitted by the footnote modifier are renumbered;
    // ordinary in-document links and anchors keep their original content.
    _ = blocks.map {
      mapBlock($0) { text in
        if case .textUrl(let link) = text, link.url.hasPrefix("#"),
          RichMessage.plainText(link.text) == "*"
        {
          let name = String(link.url.dropFirst())
          if !names.contains(name) { names.append(name) }
        }
        if case .textAnchor(let anchor) = text, definitions[anchor.name] == nil {
          definitions[anchor.name] = anchor.text
        }
        return text
      }
    }
    names.removeAll { definitions[$0] == nil }
    guard !names.isEmpty else { return blocks }
    let body = blocks.map {
      mapBlock($0) { text in
        switch text {
        case .textAnchor(let anchor) where names.contains(anchor.name):
          return .textEmpty(.init())
        case .textUrl(var link) where link.url.hasPrefix("#"):
          if let index = names.firstIndex(of: String(link.url.dropFirst())),
            RichMessage.plainText(link.text) == "*"
          {
            link.text = Text(String(index + 1)).richText
          }
          return .textUrl(link)
        default: return text
        }
      }
    }
    if let sectionTitle {
      let items: [TL.PageListOrderedItemType] = names.enumerated().compactMap { index, name in
        definitions[name].map { definition in
          .pageListOrderedItemBlocks(
            .init(
              num: String(index + 1),
              blocks: [
                .pageBlockAnchor(.init(name: name)),
                .pageBlockParagraph(.init(text: definition)),
              ]))
        }
      }
      return body
        + Details(sectionTitle) {
          TL.PageBlockType.pageBlockOrderedList(.init(items: items))
        }.blocks
    }
    return body
      + names.compactMap { name in
        definitions[name].map {
          .pageBlockFooter(.init(text: .textAnchor(.init(text: $0, name: name))))
        }
      }
  }

  private static func mapText(
    _ value: TL.RichTextType, transform: (TL.RichTextType) -> TL.RichTextType
  ) -> TL.RichTextType {
    func nested(_ text: TL.RichTextType) -> TL.RichTextType { mapText(text, transform: transform) }
    let result: TL.RichTextType
    switch value {
    case .textConcat(var value):
      value.texts = value.texts.map(nested)
      result = .textConcat(value)
    case .textBold(var value):
      value.text = nested(value.text)
      result = .textBold(value)
    case .textItalic(var value):
      value.text = nested(value.text)
      result = .textItalic(value)
    case .textUnderline(var value):
      value.text = nested(value.text)
      result = .textUnderline(value)
    case .textStrike(var value):
      value.text = nested(value.text)
      result = .textStrike(value)
    case .textFixed(var value):
      value.text = nested(value.text)
      result = .textFixed(value)
    case .textUrl(var value):
      value.text = nested(value.text)
      result = .textUrl(value)
    case .textSuperscript(var value):
      value.text = nested(value.text)
      result = .textSuperscript(value)
    case .textSubscript(var value):
      value.text = nested(value.text)
      result = .textSubscript(value)
    case .textMarked(var value):
      value.text = nested(value.text)
      result = .textMarked(value)
    case .textSpoiler(var value):
      value.text = nested(value.text)
      result = .textSpoiler(value)
    default: result = value
    }
    return transform(result)
  }

  private static func mapBlock(
    _ value: TL.PageBlockType, transform: (TL.RichTextType) -> TL.RichTextType
  ) -> TL.PageBlockType {
    func text(_ value: TL.RichTextType) -> TL.RichTextType { mapText(value, transform: transform) }
    switch value {
    case .pageBlockParagraph(var value):
      value.text = text(value.text)
      return .pageBlockParagraph(value)
    case .pageBlockFooter(var value):
      value.text = text(value.text)
      return .pageBlockFooter(value)
    case .pageBlockBlockquote(var value):
      value.text = text(value.text)
      value.caption = text(value.caption)
      return .pageBlockBlockquote(value)
    case .pageBlockDetails(var value):
      value.title = text(value.title)
      value.blocks = value.blocks.map { mapBlock($0, transform: transform) }
      return .pageBlockDetails(value)
    case .pageBlockTable(var value):
      value.title = text(value.title)
      value.rows = value.rows.map { row in
        .init(
          cells: row.cells.map { cell in
            var cell = cell
            cell.text = cell.text.map(text)
            return cell
          })
      }
      return .pageBlockTable(value)
    default: return value
    }
  }
}
