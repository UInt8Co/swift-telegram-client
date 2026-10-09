import TelegramSchema

extension RichMessage {
  /// Convert received rich-text entities to their input forms, including text
  /// inside nested blocks and captions. Media and user references still need
  /// the corresponding InputRichMessage attachments supplied by the caller.
  /// Matches TDLib's RichText::get_input_rich_text in WebPageBlock.cpp.
  public static func inputBlocks(_ blocks: [TL.PageBlockType]) -> [TL.PageBlockType] {
    blocks.map(InputRichText.block)
  }
}

private enum InputRichText {
  static func text(_ value: TL.RichTextType) -> TL.RichTextType {
    switch value {
    // Telegram generates these entities when reading input; they cannot
    // be sent back as input constructors. Retain their formatted contents.
    case .textMention(let value): return text(value.text)
    case .textHashtag(let value): return text(value.text)
    case .textBotCommand(let value): return text(value.text)
    case .textCashtag(let value): return text(value.text)
    case .textAutoUrl(let value): return text(value.text)
    case .textAutoEmail(let value): return text(value.text)
    case .textAutoPhone(let value): return text(value.text)
    case .textBankCard(let value): return text(value.text)
    case .textPlain(let value): return Text(value.text).richText
    case .textConcat(var value):
      value.texts = value.texts.map(text)
      return .textConcat(value)
    case .textBold(var value):
      value.text = text(value.text)
      return .textBold(value)
    case .textItalic(var value):
      value.text = text(value.text)
      return .textItalic(value)
    case .textUnderline(var value):
      value.text = text(value.text)
      return .textUnderline(value)
    case .textStrike(var value):
      value.text = text(value.text)
      return .textStrike(value)
    case .textFixed(var value):
      value.text = text(value.text)
      return .textFixed(value)
    case .textUrl(var value):
      value.text = text(value.text)
      value.webpageId = 0
      return .textUrl(value)
    case .textEmail(var value):
      value.text = text(value.text)
      return .textEmail(value)
    case .textSubscript(var value):
      value.text = text(value.text)
      return .textSubscript(value)
    case .textSuperscript(var value):
      value.text = text(value.text)
      return .textSuperscript(value)
    case .textMarked(var value):
      value.text = text(value.text)
      return .textMarked(value)
    case .textPhone(var value):
      value.text = text(value.text)
      return .textPhone(value)
    case .textAnchor(var value):
      value.text = text(value.text)
      return .textAnchor(value)
    case .textSpoiler(var value):
      value.text = text(value.text)
      return .textSpoiler(value)
    case .textMentionName(var value):
      value.text = text(value.text)
      return .textMentionName(value)
    case .textDate(var value):
      value.text = text(value.text)
      return .textDate(value)
    case .textDiff(var value):
      value.text = text(value.text)
      value.oldText = text(value.oldText)
      return .textDiff(value)
    case .textButton(var value):
      value.text = text(value.text)
      return .textButton(value)
    case .textEmpty, .textImage, .textMath, .textCustomEmoji: return value
    }
  }

  private static func caption(_ value: TL.PageCaption) -> TL.PageCaption {
    .init(text: text(value.text), credit: text(value.credit))
  }

  static func block(_ value: TL.PageBlockType) -> TL.PageBlockType {
    switch value {
    case .pageBlockTitle(var value):
      value.text = text(value.text)
      return .pageBlockTitle(value)
    case .pageBlockSubtitle(var value):
      value.text = text(value.text)
      return .pageBlockSubtitle(value)
    case .pageBlockAuthorDate(var value):
      value.author = text(value.author)
      return .pageBlockAuthorDate(value)
    case .pageBlockHeader(var value):
      value.text = text(value.text)
      return .pageBlockHeader(value)
    case .pageBlockSubheader(var value):
      value.text = text(value.text)
      return .pageBlockSubheader(value)
    case .pageBlockParagraph(var value):
      value.text = text(value.text)
      return .pageBlockParagraph(value)
    case .pageBlockPreformatted(var value):
      value.text = text(value.text)
      return .pageBlockPreformatted(value)
    case .pageBlockFooter(var value):
      value.text = text(value.text)
      return .pageBlockFooter(value)
    case .pageBlockKicker(var value):
      value.text = text(value.text)
      return .pageBlockKicker(value)
    case .pageBlockHeading1(var value):
      value.text = text(value.text)
      return .pageBlockHeading1(value)
    case .pageBlockHeading2(var value):
      value.text = text(value.text)
      return .pageBlockHeading2(value)
    case .pageBlockHeading3(var value):
      value.text = text(value.text)
      return .pageBlockHeading3(value)
    case .pageBlockHeading4(var value):
      value.text = text(value.text)
      return .pageBlockHeading4(value)
    case .pageBlockHeading5(var value):
      value.text = text(value.text)
      return .pageBlockHeading5(value)
    case .pageBlockHeading6(var value):
      value.text = text(value.text)
      return .pageBlockHeading6(value)
    case .pageBlockThinking(var value):
      value.text = text(value.text)
      return .pageBlockThinking(value)
    case .pageBlockBlockquote(var value):
      value.text = text(value.text)
      value.caption = text(value.caption)
      return .pageBlockBlockquote(value)
    case .pageBlockPullquote(var value):
      value.text = text(value.text)
      value.caption = text(value.caption)
      return .pageBlockPullquote(value)
    case .pageBlockPhoto(var value):
      value.caption = caption(value.caption)
      return .pageBlockPhoto(value)
    case .pageBlockVideo(var value):
      value.caption = caption(value.caption)
      return .pageBlockVideo(value)
    case .pageBlockAudio(var value):
      value.caption = caption(value.caption)
      return .pageBlockAudio(value)
    case .pageBlockDocument(var value):
      value.caption = caption(value.caption)
      return .pageBlockDocument(value)
    case .pageBlockMap(var value):
      value.caption = caption(value.caption)
      return .pageBlockMap(value)
    case .inputPageBlockMap(var value):
      value.caption = caption(value.caption)
      return .inputPageBlockMap(value)
    case .pageBlockEmbed(var value):
      value.caption = caption(value.caption)
      return .pageBlockEmbed(value)
    case .pageBlockCover(var value):
      value.cover = block(value.cover)
      return .pageBlockCover(value)
    case .pageBlockEmbedPost(var value):
      value.blocks = value.blocks.map(block)
      value.caption = caption(value.caption)
      return .pageBlockEmbedPost(value)
    case .pageBlockCollage(var value):
      value.items = value.items.map(block)
      value.caption = caption(value.caption)
      return .pageBlockCollage(value)
    case .pageBlockSlideshow(var value):
      value.items = value.items.map(block)
      value.caption = caption(value.caption)
      return .pageBlockSlideshow(value)
    case .pageBlockDetails(var value):
      value.blocks = value.blocks.map(block)
      value.title = text(value.title)
      return .pageBlockDetails(value)
    case .pageBlockBlockquoteBlocks(var value):
      value.blocks = value.blocks.map(block)
      value.caption = text(value.caption)
      return .pageBlockBlockquoteBlocks(value)
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
    case .pageBlockList(var value):
      value.items = value.items.map { item in
        switch item {
        case .pageListItemText(var item):
          item.text = text(item.text)
          return .pageListItemText(item)
        case .pageListItemBlocks(var item):
          item.blocks = item.blocks.map(block)
          return .pageListItemBlocks(item)
        }
      }
      return .pageBlockList(value)
    case .pageBlockOrderedList(var value):
      value.items = value.items.map { item in
        switch item {
        case .pageListOrderedItemText(var item):
          item.text = text(item.text)
          return .pageListOrderedItemText(item)
        case .pageListOrderedItemBlocks(var item):
          item.blocks = item.blocks.map(block)
          return .pageListOrderedItemBlocks(item)
        }
      }
      return .pageBlockOrderedList(value)
    case .pageBlockRelatedArticles(var value):
      value.title = text(value.title)
      return .pageBlockRelatedArticles(value)
    case .pageBlockButtonRow(var value):
      value.buttons = value.buttons.map { button in
        var button = button
        button.text = text(button.text)
        return button
      }
      return .pageBlockButtonRow(value)
    case .pageBlockUnsupported, .pageBlockDivider, .pageBlockAnchor, .pageBlockChannel,
      .pageBlockMath:
      return value
    }
  }
}
