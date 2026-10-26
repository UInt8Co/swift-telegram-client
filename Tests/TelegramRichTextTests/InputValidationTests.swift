import TelegramRichText
import TelegramSchema
import Testing

@Suite struct InputValidationTests {
  @Test func unsupportedDiffCannotEscapeThroughThePublicDSL() {
    let diff = Inline(
      richText: .textDiff(.init(text: Text("new").richText, oldText: Text("old").richText)))
    let message = RichMessage { Details("Change") { Paragraph(diff.bold()) } }
    #expect(throws: RichMessageValidationError.unsupportedRichText("textDiff")) {
      try message.richMessage
    }
    #expect(throws: RichMessageValidationError.unsupportedRichText("textDiff")) {
      try RichMessage.inputMessage(blocks: message.blocks)
    }
  }

  @Test func nestingUsesTheLiveTelegramBoundaryAndCannotBeBypassedByMutatingBlocks() throws {
    var inline = Inline(Text("probe"))
    for _ in 0..<15 { inline = inline.bold() }
    var message = RichMessage { Paragraph(inline) }
    _ = try message.richMessage
    message.blocks = Paragraph(inline.bold()).blocks
    #expect(throws: RichMessageValidationError.nestingTooDeep) { try message.richMessage }
  }

  @Test func nestedBlocksAlsoConsumeTheDepthBudget() throws {
    var blocks = Paragraph("probe").blocks
    for _ in 0..<15 { blocks = Details("Details") { blocks }.blocks }
    _ = try RichMessage.inputMessage(blocks: blocks)
    blocks = Details("Too deep") { blocks }.blocks
    #expect(throws: RichMessageValidationError.nestingTooDeep) {
      try RichMessage.inputMessage(blocks: blocks)
    }
  }

  @Test func textLimitsCountUnicodeScalarsAcrossTitlesCaptionsAndEmoji() throws {
    let unicode = String(repeating: "🧪", count: 32_768)
    _ = try RichMessage { Paragraph(unicode) }.richMessage
    let oversized = RichMessage {
      Details("x") { Blockquote(unicode, caption: "y") }
    }
    #expect(throws: RichMessageValidationError.textTooLong) { try oversized.richMessage }
    let emoji = RichMessage {
      Paragraph {
        Text(unicode)
        CustomEmoji(documentID: 1, alt: "x")
      }
    }
    #expect(throws: RichMessageValidationError.textTooLong) { try emoji.richMessage }
  }

  @Test func blockLimitsIncludeTableRowsAndReferenceListItems() throws {
    let paragraph = Paragraph("probe").blocks[0]
    _ = try RichMessage.inputMessage(blocks: Array(repeating: paragraph, count: 500))
    #expect(throws: RichMessageValidationError.tooManyBlocks) {
      try RichMessage.inputMessage(blocks: Array(repeating: paragraph, count: 501))
    }
    let table = RichMessage {
      Table(headers: ["Value"]) { for _ in 0..<499 { Row { "probe" } } }
    }
    #expect(throws: RichMessageValidationError.tooManyBlocks) { try table.richMessage }
    let list = TL.PageBlockType.pageBlockOrderedList(
      .init(
        items: Array(
          repeating:
            .pageListOrderedItemBlocks(.init(blocks: [paragraph])), count: 250)))
    #expect(throws: RichMessageValidationError.tooManyBlocks) {
      try RichMessage.inputMessage(blocks: [list])
    }
  }

  @Test func attachmentsAndSpanningColumnsAreBounded() {
    #expect(throws: RichMessageValidationError.tooManyAttachments) {
      try RichMessage.inputMessage(
        blocks: Paragraph("probe").blocks,
        photos: Array(repeating: .inputPhotoEmpty(.init()), count: 51))
    }
    let table = TL.PageBlockType.pageBlockTable(
      .init(
        title: Text("").richText,
        rows: [.init(cells: [.init(text: Text("probe").richText, colspan: 21)])]))
    #expect(throws: RichMessageValidationError.tooManyTableColumns) {
      try RichMessage.inputMessage(blocks: [table])
    }
  }

  @Test func emptyContainersUseTheLiveTelegramBoundary() throws {
    let paragraph = Paragraph("probe").blocks[0]
    let row = TL.PageTableRow(cells: [.init(text: Text("cell").richText)])
    func table(_ rows: [TL.PageTableRow]) -> TL.PageBlockType {
      .pageBlockTable(.init(title: .textEmpty(.init()), rows: rows))
    }
    #expect(throws: RichMessageValidationError.emptyMessage) { try RichMessage.inputMessage(blocks: []) }
    let refused: [(String, TL.PageBlockType)] = [
      ("pageBlockTable", table([])),
      ("pageTableRow", table([row, .init(cells: [])])),
      ("pageBlockDetails", Details("Outer") { paragraph; Details("Inner") {} }.blocks[0]),
      ("pageBlockList", .pageBlockList(.init(items: []))),
      ("pageBlockOrderedList", .pageBlockOrderedList(.init(items: []))),
      ("pageListItemBlocks", .pageBlockList(.init(items: [.pageListItemBlocks(.init(blocks: []))]))),
      (
        "pageListOrderedItemBlocks",
        .pageBlockOrderedList(.init(items: [.pageListOrderedItemBlocks(.init(blocks: []))]))
      ),
    ]
    for (name, block) in refused {
      #expect(throws: RichMessageValidationError.contentRequired(name)) {
        try RichMessage.inputMessage(blocks: [paragraph, block])
      }
    }
    // Telegram accepts these.
    _ = try RichMessage.inputMessage(blocks: [
      .pageBlockParagraph(.init(text: .textEmpty(.init()))),
      table([.init(cells: [.init()])]),
      .pageBlockList(.init(items: [.pageListItemText(.init(text: .textEmpty(.init())))])),
    ])
  }

  @Test func tablesWithoutHeadersOmitTheHeadingRow() throws {
    _ = try RichMessage { Table(headers: ["Only heading"]) {} }.richMessage
    guard case .pageBlockTable(let table) = Table(headers: []) { Row { "cell" } }.blocks.first else {
      Issue.record("Expected a table")
      return
    }
    #expect(table.rows.count == 1)
    _ = try RichMessage { Table(headers: []) { Row { "cell" } } }.richMessage
    #expect(Table(headers: []) {}.blocks.isEmpty)
  }
}
