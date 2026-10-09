import TelegramRichText
import TelegramSchema
import Testing

@Suite struct RichMessageTests {
  /// These custom components use only the module's public interface.
  private struct ResourceLink: InlineContent {
    let name: String
    var richText: TL.RichTextType { Text(name).link(to: "https://example.com/resource").richText }
  }

  private struct ResourceSummary: BlockContent {
    let name: String
    var blocks: [TL.PageBlockType] {
      Paragraph {
        ResourceLink(name: name)
        Text(" changed.").italic()
      }.blocks
    }
  }

  @Test(arguments: [true, false])
  func customComponentsAndConditionalCollectionsSurviveSerialization(includeExtra: Bool) throws {
    let message = RichMessage {
      Paragraph(Text("Report").bold())
      ResourceSummary(name: "Document")
      Details(summary: Text("Actions").bold()) {
        Table(headers: ["Resource", "State"]) {
          Row {
            Cell(Text("First").monospaced())
            for state in ["✅"] { Cell(state) }
          }
          for name in ["Second", "Extra"] {
            if name == "Second" || includeExtra {
              Row {
                Cell {
                  for part in [name, " item"] { Text(part) }
                  if includeExtra { Text("!") }
                }
                if includeExtra { Cell("✅") } else { Cell("❌") }
              }
            }
          }
        }
        if includeExtra { Paragraph("Extra details") }
      }
    }
    let decoded = try TL.InputRichMessageType(tlData: message.richMessage.tlSerialized())
    guard case .inputRichMessage(let rich) = decoded,
      case .pageBlockDetails(let details) = rich.blocks.last,
      case .pageBlockTable(let table) = details.blocks.first
    else {
      Issue.record("Expected native message, details, and table constructors")
      return
    }
    #expect(rich.blocks == message.blocks)
    #expect(!rich.noautolink)
    #expect(!details.open)
    #expect(table.compact)
    #expect(table.rows.count == (includeExtra ? 4 : 3))
    #expect(table.rows.allSatisfy { $0.cells.count == 2 })
    #expect(table.rows[0].cells.allSatisfy { $0.header })
    #expect(table.rows.dropFirst().allSatisfy { $0.cells.allSatisfy { !$0.header } })
    #expect(message.text.contains("Document changed."))
    #expect(message.text.contains("Extra details") == includeExtra)
    #expect(!message.text.contains("https://"))
  }

  @Test func textAndURLsRemainLiteralWhileModifiersCompose() throws {
    let label = "<b>A & B</b> [literal] _text_"
    let url = "https://example.com/?a=1&b=%3Cvalue%3E"
    let message = RichMessage {
      Paragraph(Text(label).bold().italic().monospaced().link(to: url))
    }
    guard
      case .inputRichMessage(let rich) = try TL.InputRichMessageType(
        tlData: message.richMessage.tlSerialized()),
      case .pageBlockParagraph(let paragraph) = rich.blocks.first,
      case .textUrl(let link) = paragraph.text,
      case .textFixed(let code) = link.text,
      case .textItalic(let italic) = code.text,
      case .textBold(let bold) = italic.text,
      case .textPlain(let text) = bold.text
    else {
      Issue.record("Composed modifiers must remain nested native text constructors")
      return
    }
    #expect(link.url == url)
    #expect(text.text == label)
    #expect(message.text == label)
  }

  @Test func genericFootnotesAreNumberedDeduplicatedAndPreserveModifiers() throws {
    let message = RichMessage {
      Paragraph {
        Text("First").link(to: "https://example.com/one")
          .footnote(Hashtag("#resource42"), named: "resource-42").bold()
      }
      Paragraph {
        Text("Again").footnote(Hashtag("#resource42"), named: "resource-42").italic()
        " and "
        Text("Second").footnote(Text("A & B"), named: "explanation").monospaced()
      }
    }
    let decoded = try TL.InputRichMessageType(tlData: message.richMessage.tlSerialized())
    guard case .inputRichMessage(let rich) = decoded else {
      Issue.record("Expected native rich content")
      return
    }
    let footers = rich.blocks.compactMap { block -> TL.RichTextType? in
      if case .pageBlockFooter(let footer) = block { return footer.text }
      return nil
    }
    let definitions = Self.values(of: TL.TextAnchor.self, in: footers)
    #expect(definitions.map(\.name) == ["resource-42", "explanation"])
    #expect(definitions.map { RichMessage.plainText($0.text) } == ["#resource42", "A & B"])
    let references = Self.values(of: TL.TextUrl.self, in: rich.blocks).filter {
      $0.url.hasPrefix("#")
    }
    #expect(references.map(\.url) == ["#resource-42", "#resource-42", "#explanation"])
    #expect(references.map { RichMessage.plainText($0.text) } == ["1", "1", "2"])
    #expect(Self.values(of: TL.TextHashtag.self, in: rich.blocks).isEmpty)
    #expect(Self.values(of: TL.TextBold.self, in: rich.blocks).count == 1)
    #expect(Self.values(of: TL.TextItalic.self, in: rich.blocks).count == 1)
    #expect(Self.values(of: TL.TextFixed.self, in: rich.blocks).count == 1)
  }

  @Test func longUnicodeFragmentsPreserveEveryScalar() {
    let source = String(repeating: "e\u{301} 🧑🏽‍💻 <&> ", count: 80)
    let pieces = Text.fragments(source, limit: 17)
    #expect(pieces.count > 1)
    #expect(pieces.map(\.value).joined() == source)
    #expect(pieces.allSatisfy { !$0.value.isEmpty && $0.value.utf16.count <= 17 })
    let message = RichMessage { Paragraph { for piece in pieces { piece } } }
    #expect(message.text == source)
  }

  @Test func outgoingHashtagsUsePlainTextEvenInNestedFootnotesAndTables() throws {
    let message = RichMessage {
      Paragraph(Hashtag("#issue42").bold())
      Details("Resources") {
        Table(headers: ["Reference"]) {
          Row { Hashtag("#resource7") }
          Row { Text("Peer").footnote(Hashtag("#user88"), named: "user88") }
        }
      }
    }
    guard
      case .inputRichMessage(let rich) = try TL.InputRichMessageType(
        tlData: message.richMessage.tlSerialized())
    else {
      Issue.record("Expected outgoing rich-message blocks")
      return
    }
    #expect(!rich.noautolink)
    #expect(Self.values(of: TL.TextHashtag.self, in: rich.blocks).isEmpty)
    let text = Self.values(of: TL.TextPlain.self, in: rich.blocks).map(\.text)
    for hashtag in ["#issue42", "#resource7", "#user88"] { #expect(text.contains(hashtag)) }
    #expect(Self.values(of: TL.TextAnchor.self, in: rich.blocks).map(\.name) == ["user88"])
  }

  @Test func sectionTitlesAndFootnoteBodiesRetainDetectableHashtags() throws {
    let message = RichMessage {
      Details(
        summary: Inline {
          Hashtag("#topic42")
          Text(": 2 actions")
        }
      ) {
        Paragraph(Text("Peer").footnote(Hashtag("#peer88"), named: "peer88"))
        Paragraph(Text("Again").footnote(Hashtag("#peer88"), named: "peer88"))
      }
    }
    guard
      case .inputRichMessage(let rich) = try TL.InputRichMessageType(
        tlData: message.richMessage.tlSerialized()),
      case .pageBlockDetails(let section) = rich.blocks.first,
      case .pageBlockFooter(let footer) = rich.blocks.last,
      case .textAnchor(let reference) = footer.text
    else {
      Issue.record("Expected a rich title and a separate native footnote")
      return
    }
    #expect(!rich.noautolink)
    #expect(RichMessage.plainText(section.title) == "#topic42: 2 actions")
    #expect(reference.text == Text("#peer88").richText)
    #expect(reference.name == "peer88")
    #expect(Self.values(of: TL.TextAnchor.self, in: rich.blocks).count == 1)
    #expect(Self.values(of: TL.TextHashtag.self, in: rich.blocks).isEmpty)
    #expect(
      Self.values(of: TL.TextUrl.self, in: section.blocks).allSatisfy {
        $0.url == "#peer88" && RichMessage.plainText($0.text) == "1"
      })
  }

  @Test func preformattedBlocksPreserveLiteralDiagnostics() throws {
    let text = "warning: <bad> & `code`\n  error=RICH_MESSAGE_RICH_TEXT_INVALID 🧪"
    let message = RichMessage { Preformatted(text) }
    guard
      case .inputRichMessage(let rich) = try TL.InputRichMessageType(
        tlData: message.richMessage.tlSerialized()),
      case .pageBlockPreformatted(let block) = rich.blocks.first
    else {
      Issue.record("Expected a native preformatted block")
      return
    }
    #expect(block.language.isEmpty)
    #expect(block.text == .textPlain(.init(text: text)))
    #expect(message.text == text)
    #expect(Text("").richText == .textEmpty(.init()))
  }

  @Test func ordinaryFragmentLinksKeepTheirLabels() {
    let message = RichMessage {
      TL.PageBlockType.pageBlockAnchor(.init(name: "section"))
      Paragraph(Text("*").link(to: "#section"))
    }
    let links = Self.values(of: TL.TextUrl.self, in: message.blocks)
    #expect(links.count == 1)
    #expect(links.first?.url == "#section")
    #expect(links.first.map { RichMessage.plainText($0.text) } == "*")
    #expect(message.blocks.count == 2)
  }

  @Test func expandableQuotesPreserveLiteralTextAndReferencesThroughSerialization() throws {
    let source = "{\n  \"message\": \"<b>🧑🏽‍💻 & `literal`</b>\"\n}"
    let message = RichMessage {
      Details("Response") {
        Blockquote(caption: "Raw payload", collapsed: true) { Text(source).monospaced() }
        Blockquote(Text("Summary").reference(Text("Reference"), named: "summary"))
        Blockquote("Literal <quote>")
      }
    }
    guard
      case .inputRichMessage(let rich) = try TL.InputRichMessageType(
        tlData: message.richMessage.tlSerialized()),
      case .pageBlockDetails(let section) = rich.blocks.first,
      case .pageBlockBlockquote(let quote) = section.blocks.first
    else {
      Issue.record("Expected a native collapsed section containing an expandable quote")
      return
    }
    #expect(rich.blocks == message.blocks)
    #expect(!section.open && quote.collapsed)
    #expect(quote.text == Text(source).monospaced().richText)
    #expect(RichMessage.plainText(quote.caption) == "Raw payload")
    #expect(message.text.contains(source))
    let quotes = Self.values(of: TL.PageBlockBlockquote.self, in: section.blocks)
    #expect(quotes.map(\.collapsed) == [true, false, false])
    #expect(quotes.last?.text == Text("Literal <quote>").richText)
    let references = Self.values(of: TL.TextUrl.self, in: quotes)
    #expect(references.map(\.url) == ["#summary"])
    #expect(references.map { RichMessage.plainText($0.text) } == ["1"])
    #expect(Self.values(of: TL.TextAnchor.self, in: rich.blocks).map(\.name) == ["summary"])
  }

  @Test func referencesUseSuperscriptsAndAnchoredItemsInACollapsedList() throws {
    let message = RichMessage {
      References {
        Paragraph(
          Text("First").link(to: "https://example.com").reference(
            Hashtag("#user42"), named: "user42"
          ).bold())
        Details("Rows") {
          Table(headers: ["Peer"]) {
            Row { Text("Again").reference(Hashtag("#user42"), named: "user42") }
            Row { Text("Second").reference(Hashtag("#chat42"), named: "chat42").italic() }
          }
        }
      }
    }
    guard
      case .inputRichMessage(let rich) = try TL.InputRichMessageType(
        tlData: message.richMessage.tlSerialized()),
      case .pageBlockDetails(let references) = rich.blocks.last,
      case .pageBlockOrderedList(let list) = references.blocks.first
    else {
      Issue.record("Expected a collapsed reference list")
      return
    }
    #expect(!references.open && RichMessage.plainText(references.title) == "References")
    #expect(!rich.noautolink)
    #expect(Self.values(of: TL.PageBlockFooter.self, in: rich.blocks).isEmpty)
    #expect(Self.values(of: TL.TextAnchor.self, in: rich.blocks).isEmpty)
    #expect(Self.values(of: TL.PageBlockAnchor.self, in: list).map(\.name) == ["user42", "chat42"])
    let items = Self.values(of: TL.PageListOrderedItemBlocks.self, in: list)
    #expect(items.map(\.num) == ["1", "2"])
    #expect(items.map { RichMessage(blocks: $0.blocks).text } == ["\n#user42", "\n#chat42"])
    let superscripts = Self.values(of: TL.TextSuperscript.self, in: rich.blocks)
    let links = Self.values(of: TL.TextUrl.self, in: superscripts)
    #expect(links.map(\.url) == ["#user42", "#user42", "#chat42"])
    #expect(links.map { RichMessage.plainText($0.text) } == ["1", "1", "2"])
    #expect(message.text.contains("1. #user42\n2. #chat42"))
    #expect(RichMessage(blocks: message.blocks).blocks == message.blocks)
    #expect(
      RichMessage { References { Paragraph("No references") } }.blocks
        == Paragraph("No references").blocks)
  }

  @Test func customEmojiUsesItsDocumentAndAccessibleAltText() throws {
    let message = RichMessage {
      Paragraph {
        CustomEmoji(documentID: 123, alt: "🧪")
        Text(" Pack").link(to: "https://t.me/addemoji/Pack")
      }
    }
    guard
      case .inputRichMessage(let rich) = try TL.InputRichMessageType(
        tlData: message.richMessage.tlSerialized())
    else { return }
    let emoji = Self.values(of: TL.TextCustomEmoji.self, in: rich.blocks)
    #expect(emoji == [.init(documentId: 123, alt: "🧪")])
    #expect(message.text == "🧪 Pack")
  }

  private static func values<Value>(of type: Value.Type, in value: Any) -> [Value] {
    if let found = value as? Value { return [found] }
    if value is String { return [] }
    return Mirror(reflecting: value).children.flatMap { values(of: type, in: $0.value) }
  }
}
