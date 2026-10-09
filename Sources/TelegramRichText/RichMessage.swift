import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A message built from native Telegram page blocks, never markup to parse.
public struct RichMessage: Equatable, Sendable {
  public var blocks: [TL.PageBlockType]

  public init(blocks: [TL.PageBlockType]) { self.blocks = Footnotes.resolve(in: blocks) }

  public init(@RichBlockBuilder content: () -> [TL.PageBlockType]) {
    blocks = Footnotes.resolve(in: content())
  }

  public var richMessage: TL.InputRichMessageType {
    get throws { try Self.inputMessage(blocks: blocks) }
  }

  /// Readable projection for logs, accessibility, and text assertions.
  /// Links retain their labels; URLs, anchor names, and file metadata are not text.
  public var text: String { blocks.map(Self.plainText).joined(separator: "\n") }

  public static func plainText(_ rich: TL.RichTextType) -> String {
    switch rich {
    case .textEmpty, .textImage: return ""
    case .textPlain(let value): return value.text
    case .textBold(let value): return plainText(value.text)
    case .textItalic(let value): return plainText(value.text)
    case .textUnderline(let value): return plainText(value.text)
    case .textStrike(let value): return plainText(value.text)
    case .textFixed(let value): return plainText(value.text)
    case .textUrl(let value): return plainText(value.text)
    case .textEmail(let value): return plainText(value.text)
    case .textConcat(let value): return value.texts.map(plainText).joined()
    case .textSubscript(let value): return plainText(value.text)
    case .textSuperscript(let value): return plainText(value.text)
    case .textMarked(let value): return plainText(value.text)
    case .textPhone(let value): return plainText(value.text)
    case .textAnchor(let value): return plainText(value.text)
    case .textMath(let value): return value.source
    case .textCustomEmoji(let value): return value.alt
    case .textSpoiler(let value): return plainText(value.text)
    case .textMention(let value): return plainText(value.text)
    case .textHashtag(let value): return plainText(value.text)
    case .textBotCommand(let value): return plainText(value.text)
    case .textCashtag(let value): return plainText(value.text)
    case .textAutoUrl(let value): return plainText(value.text)
    case .textAutoEmail(let value): return plainText(value.text)
    case .textAutoPhone(let value): return plainText(value.text)
    case .textBankCard(let value): return plainText(value.text)
    case .textMentionName(let value): return plainText(value.text)
    case .textDate(let value): return plainText(value.text)
    case .textDiff(let value): return plainText(value.text)
    case .textButton(let value): return plainText(value.text)
    }
  }

  public static func plainText(_ block: TL.PageBlockType) -> String {
    switch block {
    case .pageBlockDetails(let value):
      return ([plainText(value.title)] + value.blocks.map(plainText)).joined(separator: "\n")
    case .pageBlockTable(let value):
      return value.rows.map { row in
        row.cells.map { $0.text.map(plainText) ?? "" }.joined(separator: "\t")
      }.joined(separator: "\n")
    case .pageBlockOrderedList(let value):
      return value.items.enumerated().map { index, item in
        switch item {
        case .pageListOrderedItemText(let item):
          return "\(item.num ?? String(index + 1)). \(plainText(item.text))"
        case .pageListOrderedItemBlocks(let item):
          return "\(item.num ?? String(index + 1)). "
            + item.blocks.map(plainText).filter { !$0.isEmpty }.joined(separator: "\n")
        }
      }.joined(separator: "\n")
    default: return visibleText(in: block)
    }
  }

  private static func visibleText(in value: Any, depth: Int = 0) -> String {
    guard depth < 128, !(value is String), !(value is Data), !(value is TL.ChatType) else {
      return ""
    }
    if let rich = value as? TL.RichTextType { return plainText(rich) }
    return Mirror(reflecting: value).children.map { visibleText(in: $0.value, depth: depth + 1) }
      .filter { !$0.isEmpty }.joined(separator: "\n")
  }
}

@resultBuilder
public enum RichBlockBuilder {
  public static func buildExpression(_ block: TL.PageBlockType) -> [TL.PageBlockType] { [block] }
  public static func buildExpression(_ blocks: [TL.PageBlockType]) -> [TL.PageBlockType] { blocks }
  public static func buildBlock(_ parts: [TL.PageBlockType]...) -> [TL.PageBlockType] {
    parts.flatMap { $0 }
  }
  public static func buildOptional(_ part: [TL.PageBlockType]?) -> [TL.PageBlockType] { part ?? [] }
  public static func buildEither(first: [TL.PageBlockType]) -> [TL.PageBlockType] { first }
  public static func buildEither(second: [TL.PageBlockType]) -> [TL.PageBlockType] { second }
  public static func buildArray(_ parts: [[TL.PageBlockType]]) -> [TL.PageBlockType] {
    parts.flatMap { $0 }
  }
}
