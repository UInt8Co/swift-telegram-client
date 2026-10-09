import TelegramSchema

extension Writer {
  mutating func rich(_ text: TL.RichTextType, depth: Int) {
    guard guardDepth(depth) else { return }
    let next = depth + 1
    func wrap(_ name: String, _ inner: TL.RichTextType, _ attributes: [Attribute] = []) {
      element(name, attributes) { $0.rich(inner, depth: next) }
    }
    /// A link whose label is its target adds nothing to the label alone.
    func link(_ inner: TL.RichTextType, _ href: String, _ shown: String) {
      if case .textPlain(let plain) = inner, plain.text == shown {
        literal(plain.text)
      } else {
        wrap("a", inner, [.init("href", href)])
      }
    }
    switch text {
    case .textEmpty: break
    case .textPlain(let v): literal(v.text)
    case .textBold(let v): wrap("b", v.text)
    case .textItalic(let v): wrap("i", v.text)
    case .textUnderline(let v): wrap("u", v.text)
    case .textStrike(let v): wrap("s", v.text)
    case .textFixed(let v): wrap("code", v.text)
    case .textUrl(let v): link(v.text, v.url, v.url)
    case .textEmail(let v): link(v.text, "mailto:" + v.email, v.email)
    case .textPhone(let v): link(v.text, "tel:" + v.phone, v.phone)
    case .textConcat(let v): for part in v.texts { rich(part, depth: next) }
    case .textSubscript(let v): wrap("sub", v.text)
    case .textSuperscript(let v): wrap("sup", v.text)
    case .textMarked(let v): wrap("mark", v.text)
    case .textImage: void("img")
    case .textAnchor(let v): rich(v.text, depth: next)
    case .textMath(let v): element("tg-math") { $0.literal(v.source) }
    case .textCustomEmoji(let v):
      element("tg-emoji", packAttributes(renderer.customEmoji[v.documentId])) { $0.literal(v.alt) }
    case .textSpoiler(let v): wrap("tg-spoiler", v.text)
    case .textMention(let v): rich(v.text, depth: next)
    case .textHashtag(let v): rich(v.text, depth: next)
    case .textBotCommand(let v): rich(v.text, depth: next)
    case .textCashtag(let v): rich(v.text, depth: next)
    case .textAutoUrl(let v): rich(v.text, depth: next)
    case .textAutoEmail(let v): rich(v.text, depth: next)
    case .textAutoPhone(let v): rich(v.text, depth: next)
    case .textBankCard(let v): rich(v.text, depth: next)
    case .textMentionName(let v): wrap("a", v.text, [.init("href", "tg://user?id=\(v.userId)")])
    case .textDate(let v): rich(v.text, depth: next)
    case .textDiff(let v): wrap("ins", v.text)
    case .textButton(let v): wrap("tg-button", v.text, Self.buttonAttributes(v.type))
    }
  }

  mutating func blocks(_ blocks: [TL.PageBlockType], depth: Int, separator: String = "\n") {
    var first = true
    for value in blocks {
      let start = output.endIndex
      if !first { output += separator }
      let content = output.endIndex
      block(value, depth: depth)
      if output.endIndex == content { output.removeSubrange(start...) } else { first = false }
    }
  }

  private func isEmpty(_ text: TL.RichTextType) -> Bool {
    if case .textEmpty = text { return true }
    if case .textPlain(let v) = text { return v.text.isEmpty }
    return false
  }

  private mutating func caption(_ caption: TL.PageCaption, depth: Int) {
    guard !isEmpty(caption.text) || !isEmpty(caption.credit) else { return }
    element("figcaption") { writer in
      writer.rich(caption.text, depth: depth)
      if !writer.isEmpty(caption.credit) {
        writer.element("cite") { $0.rich(caption.credit, depth: depth) }
      }
    }
  }

  /// Media inside a figure when it has a caption, as in Telegram's HTML.
  private mutating func figure(
    _ caption: TL.PageCaption, depth: Int, _ media: (inout Writer) -> Void
  ) {
    if isEmpty(caption.text) && isEmpty(caption.credit) {
      media(&self)
      return
    }
    element("figure") { writer in
      media(&writer)
      writer.caption(caption, depth: depth)
    }
  }

  private mutating func quote(
    _ name: String, _ attributes: [Attribute] = [], credit: TL.RichTextType, depth: Int,
    _ body: (inout Writer) -> Void
  ) {
    element(name, attributes) { writer in
      body(&writer)
      if !writer.isEmpty(credit) { writer.element("cite") { $0.rich(credit, depth: depth) } }
    }
  }

  private mutating func block(_ block: TL.PageBlockType, depth: Int) {
    guard guardDepth(depth) else { return }
    let next = depth + 1
    func text(_ name: String, _ value: TL.RichTextType, _ attributes: [Attribute] = []) {
      element(name, attributes) { $0.rich(value, depth: next) }
    }
    switch block {
    case .pageBlockUnsupported: void("tg-media", [.init("type", "unsupported")])
    case .pageBlockAnchor: break
    case .pageBlockTitle(let v): text("h1", v.text)
    case .pageBlockSubtitle(let v): text("h2", v.text)
    case .pageBlockHeader(let v): text("h3", v.text)
    case .pageBlockSubheader(let v): text("h4", v.text)
    case .pageBlockHeading1(let v): text("h1", v.text)
    case .pageBlockHeading2(let v): text("h2", v.text)
    case .pageBlockHeading3(let v): text("h3", v.text)
    case .pageBlockHeading4(let v): text("h4", v.text)
    case .pageBlockHeading5(let v): text("h5", v.text)
    case .pageBlockHeading6(let v): text("h6", v.text)
    case .pageBlockKicker(let v): text("p", v.text)
    case .pageBlockParagraph(let v): text("p", v.text)
    case .pageBlockAuthorDate(let v): if !isEmpty(v.author) { text("p", v.author) }
    case .pageBlockFooter(let v): text("footer", v.text)
    case .pageBlockThinking(let v): text("tg-thinking", v.text)
    case .pageBlockPreformatted(let v):
      if v.language.isEmpty {
        text("pre", v.text)
      } else {
        element("pre") {
          $0.element("code", [.init("class", "language-" + v.language)]) {
            $0.rich(v.text, depth: next)
          }
        }
      }
    case .pageBlockDivider: void("hr")
    case .pageBlockMath(let v): element("tg-math-block") { $0.literal(v.source) }
    case .pageBlockList(let v):
      element("ul") { writer in
        for item in v.items {
          switch item {
          case .pageListItemText(let item):
            writer.element("li") {
              $0.checkbox(item.checkbox, item.checked)
              $0.rich(item.text, depth: next)
            }
          case .pageListItemBlocks(let item):
            writer.element("li") {
              $0.checkbox(item.checkbox, item.checked)
              $0.blocks(item.blocks, depth: next)
            }
          }
        }
      }
    case .pageBlockOrderedList(let v):
      element("ol", Self.attributes([("start", v.start.map(String.init))])) { writer in
        for item in v.items {
          switch item {
          case .pageListOrderedItemText(let item):
            writer.element("li") {
              $0.checkbox(item.checkbox, item.checked)
              $0.rich(item.text, depth: next)
            }
          case .pageListOrderedItemBlocks(let item):
            writer.element("li") {
              $0.checkbox(item.checkbox, item.checked)
              $0.blocks(item.blocks, depth: next)
            }
          }
        }
      }
    case .pageBlockBlockquote(let v):
      quote("blockquote", v.collapsed ? [.init("expandable")] : [], credit: v.caption, depth: next)
      { $0.rich(v.text, depth: next) }
    case .pageBlockBlockquoteBlocks(let v):
      quote("blockquote", credit: v.caption, depth: next) { $0.blocks(v.blocks, depth: next) }
    case .pageBlockPullquote(let v):
      quote("aside", credit: v.caption, depth: next) { $0.rich(v.text, depth: next) }
    case .pageBlockPhoto(let v):
      figure(v.caption, depth: next) {
        $0.void(
          "img", Self.attributes([("href", v.url)]) + (v.spoiler ? [.init("tg-spoiler")] : []))
      }
    case .pageBlockVideo(let v):
      figure(v.caption, depth: next) { $0.void("video", v.spoiler ? [.init("tg-spoiler")] : []) }
    case .pageBlockAudio(let v): figure(v.caption, depth: next) { $0.void("audio") }
    case .pageBlockDocument(let v): figure(v.caption, depth: next) { $0.void("tg-document") }
    case .pageBlockMap(let v): figure(v.caption, depth: next) { $0.void("tg-map") }
    case .inputPageBlockMap(let v): figure(v.caption, depth: next) { $0.void("tg-map") }
    case .pageBlockCover(let v): self.block(v.cover, depth: next)
    case .pageBlockEmbed(let v):
      figure(v.caption, depth: next) { writer in
        let attributes = Self.attributes([("url", v.url)])
        if let html = v.html, !html.isEmpty {
          writer.element("tg-embed", attributes) { $0.literal(html) }
        } else {
          writer.void("tg-embed", attributes)
        }
      }
    case .pageBlockEmbedPost(let v):
      element("tg-embed-post", Self.attributes([("url", v.url), ("author", v.author)])) { writer in
        writer.blocks(v.blocks, depth: next)
        writer.caption(v.caption, depth: next)
      }
    case .pageBlockCollage(let v):
      element("tg-collage") {
        $0.blocks(v.items, depth: next, separator: "")
        $0.caption(v.caption, depth: next)
      }
    case .pageBlockSlideshow(let v):
      element("tg-slideshow") {
        $0.blocks(v.items, depth: next, separator: "")
        $0.caption(v.caption, depth: next)
      }
    case .pageBlockChannel(let v):
      void("tg-channel", Self.attributes([("title", Self.title(v.channel))]))
    case .pageBlockTable(let v):
      element("table") { writer in
        if !writer.isEmpty(v.title) { writer.element("caption") { $0.rich(v.title, depth: next) } }
        for row in v.rows {
          writer.element("tr") { writer in
            for cell in row.cells {
              writer.element(cell.header ? "th" : "td") { writer in
                if let text = cell.text { writer.rich(text, depth: next) }
              }
            }
          }
        }
      }
    case .pageBlockDetails(let v):
      element("details", v.open ? [.init("open")] : []) { writer in
        writer.element("summary") { $0.rich(v.title, depth: next) }
        writer.blocks(v.blocks, depth: next)
      }
    case .pageBlockRelatedArticles(let v):
      element("tg-related-articles") { writer in
        writer.rich(v.title, depth: next)
        writer.element("ul") { writer in
          for article in v.articles {
            writer.element("li") { writer in
              writer.element("a", [.init("href", article.url)]) {
                $0.literal(article.title ?? article.url)
              }
              if let description = article.description, !description.isEmpty {
                writer.literal(" " + description)
              }
            }
          }
        }
      }
    case .pageBlockButtonRow(let v):
      element("tg-button-row") { writer in
        for button in v.buttons {
          writer.element("tg-button", Self.buttonAttributes(button.type)) {
            $0.rich(button.text, depth: next)
          }
        }
      }
    }
  }

  private mutating func checkbox(_ present: Bool, _ checked: Bool) {
    if present { void("input", [.init("type", "checkbox")] + (checked ? [.init("checked")] : [])) }
  }

  private static func title(_ chat: TL.ChatType) -> String? {
    switch chat {
    case .chat(let v): v.title
    case .channel(let v): v.title
    case .chatForbidden(let v): v.title
    case .channelForbidden(let v): v.title
    default: nil
    }
  }
}
