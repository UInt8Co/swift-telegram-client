import TelegramMarkup
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct MarkupRendererTests {
  private func message(
    _ text: String = "", entities: [TL.MessageEntityType] = [], media: TL.MessageMediaType? = nil,
    markup: TL.ReplyMarkupType? = nil, rich: [TL.PageBlockType]? = nil,
    from: Int64 = 2
  ) -> TL.Message {
    .init(
      id: 1, fromId: .peerUser(.init(userId: from)), peerId: .peerChannel(.init(channelId: 1)),
      date: 1,
      message: text, media: media, replyMarkup: markup, entities: entities.isEmpty ? nil : entities,
      richMessage: rich.map { .init(blocks: $0, photos: [], documents: []) })
  }

  private func plain(_ text: String) -> TL.RichTextType { .textPlain(.init(text: text)) }

  @Test func formattingEntitiesBecomeTelegramHTMLTags() {
    let output = MarkupRenderer().render(
      text: "Bold italic link code",
      entities: [
        .messageEntityBold(.init(offset: 0, length: 4)),
        .messageEntityItalic(.init(offset: 5, length: 6)),
        .messageEntityTextUrl(
          .init(offset: 12, length: 4, url: "https://example.com/?a=1&b=\"2\"")),
        .messageEntityCode(.init(offset: 17, length: 4)),
      ])
    #expect(
      output.markup
        == #"<b>Bold</b> <i>italic</i> <a href="https://example.com/?a=1&amp;b=&quot;2&quot;">link</a> <code>code</code>"#
    )
    #expect(output.isComplete)
  }

  @Test func detectedEntitiesStayPlainText() {
    let text = "@someone #tag /start https://t.me $USD"
    let output = MarkupRenderer().render(
      text: text,
      entities: [
        .messageEntityMention(.init(offset: 0, length: 8)),
        .messageEntityHashtag(.init(offset: 9, length: 4)),
        .messageEntityBotCommand(.init(offset: 14, length: 6)),
        .messageEntityUrl(.init(offset: 21, length: 14)),
        .messageEntityCashtag(.init(offset: 36, length: 4)),
      ])
    #expect(output.markup == text)
  }

  @Test func overlappingEntitiesStayWellNested() {
    let output = MarkupRenderer().render(
      text: "abcdefgh",
      entities: [
        .messageEntityBold(.init(offset: 0, length: 5)),
        .messageEntityItalic(.init(offset: 3, length: 5)),
      ])
    #expect(output.markup == "<b>abc<i>de</i></b><i>fgh</i>")
  }

  @Test func sameRangeEntitiesKeepTheirOrder() {
    let output = MarkupRenderer().render(
      text: "x",
      entities: [
        .messageEntityUnderline(.init(offset: 0, length: 1)),
        .messageEntitySpoiler(.init(offset: 0, length: 1)),
      ])
    #expect(output.markup == "<u><tg-spoiler>x</tg-spoiler></u>")
  }

  @Test func offsetsCountUTF16UnitsAndRejectSplitSurrogates() {
    let output = MarkupRenderer().render(
      text: "😀 hi", entities: [.messageEntityBold(.init(offset: 3, length: 2))])
    #expect(output.markup == "😀 <b>hi</b>")
    let split = MarkupRenderer().render(
      text: "😀", entities: [.messageEntityBold(.init(offset: 1, length: 1))])
    #expect(split.markup == "😀")
    #expect(!split.isComplete)
    let outside = MarkupRenderer().render(
      text: "abc", entities: [.messageEntityBold(.init(offset: 2, length: 5))])
    #expect(!outside.isComplete)
  }

  @Test func participantTextCannotForgeMarkup() {
    let output = MarkupRenderer().render(
      text: #"<tg-button type="url">x</tg-button> & "q""#, entities: [])
    #expect(output.markup == #"&lt;tg-button type="url"&gt;x&lt;/tg-button&gt; &amp; "q""#)
    #expect(
      MarkupRenderer.visibleText(output.markup) == #"<tg-button type="url">x</tg-button> & "q""#)
  }

  @Test func customEmojiCarriesItsPackWhenKnown() {
    let renderer = MarkupRenderer(customEmoji: [
      55: .init(title: "Party \"Pack\"", shortName: "party_pack")
    ])
    let output = renderer.render(
      text: "😀 🔥",
      entities: [
        .messageEntityCustomEmoji(.init(offset: 0, length: 2, documentId: 55)),
        .messageEntityCustomEmoji(.init(offset: 3, length: 2, documentId: 66)),
      ])
    #expect(
      output.markup
        == #"<tg-emoji pack="Party &quot;Pack&quot;" pack-name="party_pack">😀</tg-emoji> <tg-emoji>🔥</tg-emoji>"#
    )
  }

  @Test func blockquotesPreAndMentionsUseTelegramForms() {
    let output = MarkupRenderer().render(
      text: "quoted code Alex",
      entities: [
        .messageEntityBlockquote(.init(collapsed: true, offset: 0, length: 6)),
        .messageEntityPre(.init(offset: 7, length: 4, language: "swift")),
        .messageEntityMentionName(.init(offset: 12, length: 4, userId: 9)),
      ])
    #expect(
      output.markup
        == #"<blockquote expandable>quoted</blockquote> <pre><code class="language-swift">code</code></pre> <a href="tg://user?id=9">Alex</a>"#
    )
  }

  @Test func messagesJoinTextMediaAndButtons() {
    let value = message(
      "Join now", media: .messageMediaPhoto(.init(spoiler: true)),
      markup: .replyInlineMarkup(
        .init(rows: [
          .init(buttons: [
            .init(text: "Open", type: .inlineButtonTypeUrl(.init(url: "https://example.com/open"))),
            .init(text: "Copy", type: .inlineButtonTypeCopy(.init(copyText: "CODE42"))),
          ]),
          .init(buttons: [
            .init(
              text: "Callback", type: .inlineButtonTypeCallback(.init(data: Data("secret".utf8))))
          ]),
        ])))
    let output = MarkupRenderer().render(value)
    #expect(
      output.markup == """
        Join now
        <img tg-spoiler/>
        <tg-button-row><tg-button type="url" url="https://example.com/open">Open</tg-button><tg-button type="copy_text" text="CODE42">Copy</tg-button></tg-button-row><tg-button-row><tg-button type="callback_data">Callback</tg-button></tg-button-row>
        """)
    #expect(!output.markup.contains("secret"))
  }

  @Test func documentsDescribeKindNameAndStickerPack() {
    let sticker = TL.DocumentType.document(
      .init(
        id: 1, accessHash: 2, fileReference: Data(), date: 1, mimeType: "image/webp",
        size: 10, dcId: 1,
        attributes: [
          .documentAttributeSticker(
            .init(
              alt: "😎",
              stickerset: .inputStickerSetID(.init(id: 7, accessHash: 8))))
        ]))
    let renderer = MarkupRenderer(stickerSets: [7: .init(title: "Cool", shortName: "cool_pack")])
    #expect(
      renderer.render(.messageMediaDocument(.init(document: sticker))).markup
        == #"<tg-sticker emoji="😎" pack="Cool" pack-name="cool_pack"/>"#)
    let file = TL.DocumentType.document(
      .init(
        id: 1, accessHash: 2, fileReference: Data(), date: 1, mimeType: "application/zip",
        size: 10, dcId: 1, attributes: [.documentAttributeFilename(.init(fileName: "notes.zip"))]))
    #expect(
      MarkupRenderer().render(.messageMediaDocument(.init(document: file))).markup
        == #"<tg-document name="notes.zip" type="application/zip"/>"#)
    let voice = TL.DocumentType.document(
      .init(
        id: 1, accessHash: 2, fileReference: Data(), date: 1, mimeType: "audio/ogg",
        size: 10, dcId: 1, attributes: [.documentAttributeAudio(.init(voice: true, duration: 3))]))
    #expect(
      MarkupRenderer().render(.messageMediaDocument(.init(document: voice))).markup
        == "<audio voice/>")
  }

  @Test func pollsMarkAnswersAddedByOthers() {
    let poll = TL.MessageMediaType.messageMediaPoll(
      .init(
        poll: .init(
          id: 1, question: .init(text: "Lunch?", entities: []),
          answers: [
            .pollAnswer(.init(text: .init(text: "Yes", entities: []), option: Data([0]))),
            .pollAnswer(
              .init(
                text: .init(text: "Pizza", entities: []), option: Data([1]),
                addedBy: .peerUser(.init(userId: 5)), date: 1)),
          ], hash: 0), results: .init()))
    let output = MarkupRenderer().render(message(media: poll))
    #expect(
      output.markup
        == #"<tg-poll>Lunch?<ol><li>Yes</li><li added-by="user:5">Pizza</li></ol></tg-poll>"#)
  }

  @Test func previewsShowOnlyTelegramSuppliedFields() {
    let page = TL.MessageMediaType.messageMediaWebPage(
      .init(
        webpage: .webPage(
          .init(
            id: 1, url: "https://x.example",
            displayUrl: "x.example", hash: 0, siteName: "X", title: "Example page",
            description: "Click <here>"))))
    #expect(
      MarkupRenderer().render(page).markup
        == #"<tg-preview url="https://x.example" site="X" title="Example page">Click &lt;here&gt;</tg-preview>"#
    )
    let empty = TL.MessageMediaType.messageMediaWebPage(
      .init(webpage: .webPageEmpty(.init(id: 1, url: "https://t.me/+abc"))))
    #expect(MarkupRenderer().render(empty).markup == #"<tg-preview url="https://t.me/+abc"/>"#)
  }

  @Test func richBlocksUseRichHTMLStyle() {
    let blocks: [TL.PageBlockType] = [
      .pageBlockHeading1(.init(text: plain("Weekly digest"))),
      .pageBlockParagraph(
        .init(
          text: .textConcat(
            .init(texts: [
              plain("Contact "), .textMention(.init(text: plain("@someone"))),
              plain(" "),
              .textUrl(.init(text: plain("here"), url: "https://link.example", webpageId: 0)),
              plain(" "),
              .textUrl(
                .init(
                  text: plain("https://same.example"), url: "https://same.example", webpageId: 0)),
              .textCustomEmoji(.init(documentId: 3, alt: "🎉")),
            ])))),
      .pageBlockBlockquote(.init(text: plain("Someone else"), caption: plain("Author"))),
      .pageBlockList(
        .init(items: [.pageListItemText(.init(checkbox: true, checked: true, text: plain("done")))])
      ),
      .pageBlockDetails(
        .init(open: true, blocks: [.pageBlockDivider(.init())], title: plain("More"))),
      .pageBlockButtonRow(
        .init(buttons: [
          .init(
            text: .textBold(.init(text: plain("Go"))),
            type: .inlineButtonTypeUrl(.init(url: "https://go.example")))
        ])),
    ]
    #expect(
      MarkupRenderer().render(blocks).markup == """
        <h1>Weekly digest</h1>
        <p>Contact @someone <a href="https://link.example">here</a> https://same.example<tg-emoji>🎉</tg-emoji></p>
        <blockquote>Someone else<cite>Author</cite></blockquote>
        <ul><li><input type="checkbox" checked/>done</li></ul>
        <details open><summary>More</summary><hr/></details>
        <tg-button-row><tg-button type="url" url="https://go.example"><b>Go</b></tg-button></tg-button-row>
        """)
  }

  @Test func figuresAndTablesKeepCaptionsAndCells() {
    let blocks: [TL.PageBlockType] = [
      .pageBlockPhoto(
        .init(photoId: 1, caption: .init(text: plain("Sunset"), credit: .textEmpty(.init())))),
      .pageBlockPhoto(
        .init(photoId: 2, caption: .init(text: .textEmpty(.init()), credit: .textEmpty(.init())))),
      .pageBlockTable(
        .init(
          title: plain("Prices"),
          rows: [
            .init(cells: [
              .init(header: true, text: plain("Plan")), .init(header: true, text: plain("Price")),
            ]),
            .init(cells: [.init(text: plain("Pro")), .init(text: plain("$5"))]),
          ])),
    ]
    #expect(
      MarkupRenderer().render(blocks).markup == """
        <figure><img/><figcaption>Sunset</figcaption></figure>
        <img/>
        <table><caption>Prices</caption><tr><th>Plan</th><th>Price</th></tr><tr><td>Pro</td><td>$5</td></tr></table>
        """)
  }

  @Test func excessiveNestingIsReportedIncomplete() {
    var text = plain("deep")
    for _ in 0..<40 { text = .textBold(.init(text: text)) }
    let output = MarkupRenderer().render(text)
    #expect(!output.isComplete)
    #expect(!output.markup.contains("deep"))
  }

  @Test func visibleTextDropsTagsAndUnescapes() {
    #expect(
      MarkupRenderer.visibleText(#"<b>a &amp; b</b> <tg-emoji pack="x">😀</tg-emoji> 1 &lt; 2 & 3"#)
        == "a & b 😀 1 < 2 & 3")
  }
}
