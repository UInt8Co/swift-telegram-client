import TelegramSchema

/// Composable inline content. Only the DSL's rendering layer knows TL shapes.
public protocol InlineContent: Sendable {
  var richText: TL.RichTextType { get }
}

public struct Text: InlineContent {
  public let value: String
  public init(_ value: String) { self.value = value }
  public var richText: TL.RichTextType {
    value.isEmpty ? .textEmpty(.init()) : .textPlain(.init(text: value))
  }

  public static func fragments(_ value: String, limit: Int = 500) -> [Text] {
    splitText(value, limit: limit).map(Text.init)
  }
}

public struct Inline: InlineContent {
  public let richText: TL.RichTextType
  public init(_ content: some InlineContent) { richText = content.richText }
  public init(richText: TL.RichTextType) { self.richText = richText }
  public init(@InlineBuilder content: () -> Inline) { self = content() }
}

extension InlineContent {
  public func bold() -> Inline { .init(richText: .textBold(.init(text: richText))) }
  public func italic() -> Inline { .init(richText: .textItalic(.init(text: richText))) }
  public func monospaced() -> Inline { .init(richText: .textFixed(.init(text: richText))) }
  public func link(to url: String) -> Inline {
    .init(richText: .textUrl(.init(text: richText, url: url, webpageId: 0)))
  }
  public func footnote(_ text: String, named name: String) -> Inline {
    footnote(Text(text), named: name)
  }
  public func footnote(_ content: some InlineContent, named name: String) -> Inline {
    reference(content, named: name)
  }
  /// A numbered superscript link, collected into a list by `References`.
  public func reference(_ content: some InlineContent, named name: String) -> Inline {
    .init(
      richText: .textConcat(
        .init(texts: [
          richText,
          .textSuperscript(.init(text: Text("*").link(to: "#\(name)").richText)),
          .textAnchor(.init(text: content.richText, name: name)),
        ])))
  }
}

public struct CustomEmoji: InlineContent {
  public let documentID: Int64
  public let alt: String
  public init(documentID: Int64, alt: String = "▫️") {
    self.documentID = documentID
    self.alt = alt
  }
  public var richText: TL.RichTextType { .textCustomEmoji(.init(documentId: documentID, alt: alt)) }
}

public struct Hashtag: InlineContent {
  public let value: String
  public init(_ value: String) { self.value = value }
  // textHashtag is a server-generated entity, not an input constructor.
  // Like TDLib's get_input_rich_text, send its text and let Telegram detect it.
  public var richText: TL.RichTextType { Text(value).richText }
}

@resultBuilder
public enum InlineBuilder {
  public static func buildExpression(_ content: some InlineContent) -> [TL.RichTextType] {
    [content.richText]
  }
  public static func buildExpression(_ text: String) -> [TL.RichTextType] { [Text(text).richText] }
  public static func buildBlock(_ parts: [TL.RichTextType]...) -> [TL.RichTextType] {
    parts.flatMap { $0 }
  }
  public static func buildOptional(_ part: [TL.RichTextType]?) -> [TL.RichTextType] { part ?? [] }
  public static func buildEither(first: [TL.RichTextType]) -> [TL.RichTextType] { first }
  public static func buildEither(second: [TL.RichTextType]) -> [TL.RichTextType] { second }
  public static func buildArray(_ parts: [[TL.RichTextType]]) -> [TL.RichTextType] {
    parts.flatMap { $0 }
  }
  public static func buildFinalResult(_ parts: [TL.RichTextType]) -> Inline {
    .init(richText: parts.count == 1 ? parts[0] : .textConcat(.init(texts: parts)))
  }
}

public protocol BlockContent: Sendable {
  var blocks: [TL.PageBlockType] { get }
}

extension RichBlockBuilder {
  public static func buildExpression(_ content: some BlockContent) -> [TL.PageBlockType] {
    content.blocks
  }
}

public struct Paragraph: BlockContent {
  public let content: Inline
  public init(_ content: some InlineContent) { self.content = Inline(content) }
  public init(_ text: String) { content = Inline(Text(text)) }
  public init(@InlineBuilder content: () -> Inline) { self.content = content() }
  public var blocks: [TL.PageBlockType] { [.pageBlockParagraph(.init(text: content.richText))] }
}

/// Literal code or diagnostic text, with whitespace preserved and no markup parsing.
public struct Preformatted: BlockContent {
  public let text: String
  public let language: String
  public init(_ text: String, language: String = "") {
    self.text = text
    self.language = language
  }
  public var blocks: [TL.PageBlockType] {
    [.pageBlockPreformatted(.init(text: Text(text).richText, language: language))]
  }
}

/// A native quote that can start collapsed and expand in the Telegram client.
public struct Blockquote: BlockContent {
  public let content: Inline
  public let caption: String
  public let collapsed: Bool

  public init(_ content: some InlineContent, caption: String = "", collapsed: Bool = false) {
    self.content = Inline(content)
    self.caption = caption
    self.collapsed = collapsed
  }
  public init(_ text: String, caption: String = "", collapsed: Bool = false) {
    self.init(Text(text), caption: caption, collapsed: collapsed)
  }
  public init(caption: String = "", collapsed: Bool = false, @InlineBuilder content: () -> Inline) {
    self.init(content(), caption: caption, collapsed: collapsed)
  }
  public var blocks: [TL.PageBlockType] {
    [
      .pageBlockBlockquote(
        .init(collapsed: collapsed, text: content.richText, caption: Text(caption).richText))
    ]
  }
}

public struct Details: BlockContent {
  public let summary: Inline
  public let content: [TL.PageBlockType]
  public init(_ summary: String, @RichBlockBuilder content: () -> [TL.PageBlockType]) {
    self.summary = Inline(Text(summary))
    self.content = content()
  }
  public init(summary: some InlineContent, @RichBlockBuilder content: () -> [TL.PageBlockType]) {
    self.summary = Inline(summary)
    self.content = content()
  }
  public var blocks: [TL.PageBlockType] {
    [.pageBlockDetails(.init(blocks: content, title: summary.richText))]
  }
}

/// Renders content followed by a collapsed, deduplicated reference list.
/// Every list item has a block anchor; these are in-page links, not footnotes.
public struct References: BlockContent {
  public let title: String
  public let content: [TL.PageBlockType]
  public init(_ title: String = "References", @RichBlockBuilder content: () -> [TL.PageBlockType]) {
    self.title = title
    self.content = content()
  }
  public var blocks: [TL.PageBlockType] { Footnotes.resolve(in: content, sectionTitle: title) }
}

public struct Cell: Sendable {
  public let content: Inline
  public init(_ content: some InlineContent) { self.content = Inline(content) }
  public init(_ text: String) { content = Inline(Text(text)) }
  public init(@InlineBuilder content: () -> Inline) { self.content = content() }
}

public struct Row: Sendable {
  public let cells: [Cell]
  public init(@CellBuilder content: () -> [Cell]) { cells = content() }
}

@resultBuilder
public enum CellBuilder {
  public static func buildExpression(_ cell: Cell) -> [Cell] { [cell] }
  public static func buildExpression(_ content: some InlineContent) -> [Cell] { [Cell(content)] }
  public static func buildExpression(_ text: String) -> [Cell] { [Cell(text)] }
  public static func buildBlock(_ parts: [Cell]...) -> [Cell] { parts.flatMap { $0 } }
  public static func buildOptional(_ part: [Cell]?) -> [Cell] { part ?? [] }
  public static func buildEither(first: [Cell]) -> [Cell] { first }
  public static func buildEither(second: [Cell]) -> [Cell] { second }
  public static func buildArray(_ parts: [[Cell]]) -> [Cell] { parts.flatMap { $0 } }
}

public struct Table: BlockContent {
  public let headers: [String]
  public let rows: [Row]
  public init(headers: [String], @RowBuilder content: () -> [Row]) {
    self.headers = headers
    rows = content()
  }
  public var blocks: [TL.PageBlockType] {
    let heading = TL.PageTableRow(
      cells: headers.map { .init(header: true, text: Text($0).richText) })
    let body = rows.map {
      TL.PageTableRow(cells: $0.cells.map { .init(text: $0.content.richText) })
    }
    return [
      .pageBlockTable(.init(compact: true, title: .textEmpty(.init()), rows: [heading] + body))
    ]
  }
}

@resultBuilder
public enum RowBuilder {
  public static func buildExpression(_ row: Row) -> [Row] { [row] }
  public static func buildExpression(_ rows: [Row]) -> [Row] { rows }
  public static func buildBlock(_ parts: [Row]...) -> [Row] { parts.flatMap { $0 } }
  public static func buildOptional(_ part: [Row]?) -> [Row] { part ?? [] }
  public static func buildEither(first: [Row]) -> [Row] { first }
  public static func buildEither(second: [Row]) -> [Row] { second }
  public static func buildArray(_ parts: [[Row]]) -> [Row] { parts.flatMap { $0 } }
}

/// Split on Unicode scalar boundaries, never inside a UTF-16 surrogate pair.
/// An indivisible scalar may require two units even if the requested limit is one.
private func splitText(_ value: String, limit: Int) -> [String] {
  precondition(limit > 0, "The text fragment limit must be positive")
  var result: [String] = []
  var current = ""
  var length = 0
  for scalar in value.unicodeScalars {
    let size = scalar.value > 0xffff ? 2 : 1
    if length + size > limit, !current.isEmpty {
      result.append(current)
      current = ""
      length = 0
    }
    current.unicodeScalars.append(scalar)
    length += size
  }
  if !current.isEmpty || result.isEmpty { result.append(current) }
  return result
}
