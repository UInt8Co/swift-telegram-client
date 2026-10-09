import TelegramRichText
import TelegramSchema
import Testing

@Suite struct InputRichTextTests {
  private static let label = Text("#tag @name /command $USD https://example.com 🧪").bold().richText
  private static let receivedEntities: [TL.RichTextType] = [
    .textMention(.init(text: label)), .textHashtag(.init(text: label)),
    .textBotCommand(.init(text: label)), .textCashtag(.init(text: label)),
    .textAutoUrl(.init(text: label)), .textAutoEmail(.init(text: label)),
    .textAutoPhone(.init(text: label)), .textBankCard(.init(text: label)),
  ]

  @Test(arguments: receivedEntities)
  func receivedEntitiesBecomeInputTextWithoutLosingFormatting(entity: TL.RichTextType) throws {
    let message = RichMessage { Paragraph(Inline(richText: entity)) }
    guard
      case .inputRichMessage(let input) = try TL.InputRichMessageType(
        tlData: message.richMessage.tlSerialized())
    else {
      Issue.record("Expected native input blocks")
      return
    }
    #expect(input.blocks == Paragraph(Inline(richText: Self.label)).blocks)
    #expect(!input.noautolink)
    #expect(
      message.blocks == Paragraph(Inline(richText: entity)).blocks,
      "The source must remain unchanged")
  }

  @Test func conversionReachesEveryInlineContainerAndBothDiffBranches() {
    func containers(_ text: TL.RichTextType) -> [TL.RichTextType] {
      [
        .textBold(.init(text: text)), .textItalic(.init(text: text)),
        .textUnderline(.init(text: text)), .textStrike(.init(text: text)),
        .textFixed(.init(text: text)), .textUrl(.init(text: text, url: "#reference", webpageId: 0)),
        .textEmail(.init(text: text, email: "a@example.com")),
        .textConcat(.init(texts: [text, text])), .textSubscript(.init(text: text)),
        .textSuperscript(.init(text: text)), .textMarked(.init(text: text)),
        .textPhone(.init(text: text, phone: "+1234567")),
        .textAnchor(.init(text: text, name: "ref")),
        .textSpoiler(.init(text: text)), .textMentionName(.init(text: text, userId: 42)),
        .textDate(.init(relative: true, text: text, date: 100)),
        .textDiff(.init(text: text, oldText: text)),
        .textButton(
          .init(text: text, type: .inlineButtonTypeUrl(.init(url: "https://example.com")))),
      ]
    }
    let received = containers(.textHashtag(.init(text: Self.label))).map {
      TL.PageBlockType.pageBlockParagraph(.init(text: $0))
    }
    let expected = containers(Self.label).map {
      TL.PageBlockType.pageBlockParagraph(.init(text: $0))
    }
    #expect(RichMessage.inputBlocks(received) == expected)
    #expect(RichMessage.inputBlocks(expected) == expected)
  }

  @Test func conversionReachesNestedListsTablesCaptionsAndTitles() throws {
    func blocks(_ text: TL.RichTextType) -> [TL.PageBlockType] {
      let paragraph = TL.PageBlockType.pageBlockParagraph(.init(text: text))
      let caption = TL.PageCaption(text: text, credit: text)
      return [
        .pageBlockDetails(
          .init(
            open: true,
            blocks: [
              .pageBlockTable(
                .init(
                  compact: true, title: text,
                  rows: [
                    .init(cells: [.init(header: true, text: text, colspan: 2), .init()])
                  ])),
              .pageBlockList(
                .init(items: [
                  .pageListItemText(.init(checkbox: true, checked: true, text: text)),
                  .pageListItemBlocks(.init(blocks: [paragraph])),
                ])),
              .pageBlockOrderedList(
                .init(
                  reversed: true,
                  items: [
                    .pageListOrderedItemText(.init(num: "4", text: text)),
                    .pageListOrderedItemBlocks(.init(num: "5", blocks: [paragraph])),
                  ], start: 4)),
              .pageBlockBlockquoteBlocks(.init(blocks: [paragraph], caption: text)),
              .pageBlockBlockquote(.init(collapsed: true, text: text, caption: text)),
              .pageBlockPullquote(.init(text: text, caption: text)),
              .pageBlockPhoto(.init(photoId: 42, caption: caption)),
              .pageBlockVideo(.init(autoplay: true, videoId: 43, caption: caption)),
              .pageBlockAudio(.init(audioId: 44, caption: caption)),
              .pageBlockDocument(.init(documentId: 45, caption: caption)),
              .pageBlockCover(.init(cover: paragraph)),
              .pageBlockCollage(.init(items: [paragraph], caption: caption)),
              .pageBlockSlideshow(.init(items: [paragraph], caption: caption)),
              .pageBlockEmbedPost(
                .init(
                  url: "https://example.com", webpageId: 0,
                  authorPhotoId: 0, author: "Author", date: 1, blocks: [paragraph], caption: caption
                )),
              .pageBlockEmbed(.init(url: "https://example.com", caption: caption)),
              .pageBlockMap(
                .init(geo: .geoPointEmpty(.init()), zoom: 1, w: 10, h: 10, caption: caption)),
              .inputPageBlockMap(
                .init(geo: .inputGeoPointEmpty(.init()), zoom: 1, w: 10, h: 10, caption: caption)),
              .pageBlockRelatedArticles(.init(title: text, articles: [])),
              .pageBlockButtonRow(
                .init(buttons: [
                  .init(
                    text: text,
                    type: .inlineButtonTypeUrl(.init(url: "https://example.com")))
                ])),
            ], title: text)),
        .pageBlockTitle(.init(text: text)), .pageBlockSubtitle(.init(text: text)),
        .pageBlockAuthorDate(.init(author: text, publishedDate: 1)),
        .pageBlockHeader(.init(text: text)), .pageBlockSubheader(.init(text: text)),
        .pageBlockHeading1(.init(text: text)), .pageBlockHeading2(.init(text: text)),
        .pageBlockHeading3(.init(text: text)), .pageBlockHeading4(.init(text: text)),
        .pageBlockHeading5(.init(text: text)), .pageBlockHeading6(.init(text: text)),
        .pageBlockKicker(.init(text: text)), .pageBlockThinking(.init(text: text)),
        .pageBlockPreformatted(.init(text: text, language: "swift")),
        .pageBlockFooter(.init(text: text)),
      ]
    }
    let received = blocks(.textHashtag(.init(text: Self.label)))
    let input = TL.InputRichMessageType.inputRichMessage(
      .init(blocks: RichMessage.inputBlocks(received)))
    guard
      case .inputRichMessage(let decoded) = try TL.InputRichMessageType(
        tlData: input.tlSerialized())
    else {
      Issue.record("Expected native input blocks")
      return
    }
    #expect(decoded.blocks == blocks(Self.label))
  }

  @Test func explicitURLsKeepTargetsButDiscardReceivedWebpageIDs() {
    let received = TL.RichTextType.textUrl(
      .init(
        text: Self.receivedEntities[0],
        url: "https://example.com/?x=1&y=2", webpageId: 99))
    let blocks = RichMessage.inputBlocks(Paragraph(Inline(richText: received)).blocks)
    #expect(
      blocks
        == Paragraph(
          Inline(
            richText: .textUrl(
              .init(
                text: Self.label,
                url: "https://example.com/?x=1&y=2", webpageId: 0)))
        ).blocks)
  }
}
