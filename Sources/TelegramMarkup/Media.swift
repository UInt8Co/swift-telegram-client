import TelegramSchema

extension Writer {
  /// Media contents are never available; tags state only what kind of media
  /// was attached and its textual metadata.
  mutating func media(_ media: TL.MessageMediaType, author: TL.PeerType?, depth: Int) {
    guard guardDepth(depth) else { return }
    switch media {
    case .messageMediaEmpty: break
    case .messageMediaPhoto(let value): void("img", value.spoiler ? [.init("tg-spoiler")] : [])
    case .messageMediaDocument(let value): document(value)
    case .messageMediaGeo, .messageMediaGeoLive: void("tg-map")
    case .messageMediaVenue(let value):
      void("tg-venue", Self.attributes([("title", value.title), ("address", value.address)]))
    case .messageMediaContact(let value):
      let name = [value.firstName, value.lastName].filter { !$0.isEmpty }.joined(separator: " ")
      let attributes = Self.attributes([("name", name), ("phone", value.phoneNumber)])
      if value.vcard.isEmpty {
        void("tg-contact", attributes)
      } else {
        element("tg-contact", attributes) { $0.literal(value.vcard) }
      }
    case .messageMediaPoll(let value): poll(value, author: author)
    case .messageMediaWebPage(let value): webPage(value.webpage, depth: depth)
    case .messageMediaGame(let value):
      element("tg-game", Self.attributes([("title", value.game.title)])) {
        $0.literal(value.game.description)
      }
    case .messageMediaInvoice(let value):
      element(
        "tg-invoice",
        Self.attributes([
          ("title", value.title), ("currency", value.currency),
          ("amount", String(value.totalAmount)),
        ])
      ) { $0.literal(value.description) }
    case .messageMediaDice(let value):
      void("tg-dice", Self.attributes([("emoji", value.emoticon), ("value", String(value.value))]))
    case .messageMediaStory(let value):
      var caption: String?
      if case .storyItem(let story) = value.story { caption = story.caption }
      let attributes = [Attribute("from", MarkupRenderer.peer(value.peer))]
      if let caption, !caption.isEmpty {
        element("tg-story", attributes) { $0.text(caption, entities: []) }
      } else {
        void("tg-story", attributes)
      }
    case .messageMediaGiveaway(let value):
      let attributes = Self.attributes([("quantity", String(value.quantity))])
      if let prize = value.prizeDescription, !prize.isEmpty {
        element("tg-giveaway", attributes) { $0.literal(prize) }
      } else {
        void("tg-giveaway", attributes)
      }
    case .messageMediaGiveawayResults: void("tg-giveaway-results")
    case .messageMediaPaidMedia(let value):
      void("tg-paid-media", [.init("stars", String(value.starsAmount))])
    case .messageMediaToDo(let value):
      element("tg-todo") {
        $0.text(value.todo.title.text, entities: value.todo.title.entities)
        $0.element("ul") { writer in
          for item in value.todo.list {
            writer.element("li") { $0.text(item.title.text, entities: item.title.entities) }
          }
        }
      }
    case .messageMediaUnsupported: void("tg-media", [.init("type", "unsupported")])
    case .messageMediaVideoStream: void("tg-media", [.init("type", "live-stream")])
    }
  }

  private mutating func document(_ value: TL.MessageMediaDocument) {
    let spoiler: [Attribute] = value.spoiler ? [.init("tg-spoiler")] : []
    guard case .document(let document)? = value.document else {
      void(value.voice ? "audio" : value.round || value.video ? "video" : "tg-document", spoiler)
      return
    }
    var name: String?
    var animated = false
    var sticker: (alt: String, set: TL.InputStickerSetType)?
    var audio: TL.DocumentAttributeAudio?
    var video: TL.DocumentAttributeVideo?
    for attribute in document.attributes {
      switch attribute {
      case .documentAttributeFilename(let a): name = a.fileName
      case .documentAttributeAnimated: animated = true
      case .documentAttributeSticker(let a): sticker = (a.alt, a.stickerset)
      case .documentAttributeCustomEmoji(let a): sticker = (a.alt, a.stickerset)
      case .documentAttributeAudio(let a): audio = a
      case .documentAttributeVideo(let a): video = a
      default: break
      }
    }
    if let sticker {
      void(
        "tg-sticker",
        Self.attributes([("emoji", sticker.alt)]) + packAttributes(pack(sticker.set)) + spoiler)
    } else if let audio {
      if audio.voice || value.voice {
        void("audio", [.init("voice")] + spoiler)
      } else {
        void(
          "audio",
          Self.attributes([("title", audio.title), ("performer", audio.performer)]) + spoiler)
      }
    } else if animated {
      void("video", [.init("gif")] + spoiler)
    } else if let video {
      void("video", (video.roundMessage || value.round ? [.init("round")] : []) + spoiler)
    } else {
      void("tg-document", Self.attributes([("name", name), ("type", document.mimeType)]) + spoiler)
    }
  }

  /// Answers someone else added are marked, so they do not read as the
  /// poll author's own words.
  private mutating func poll(_ value: TL.MessageMediaPoll, author: TL.PeerType?) {
    element("tg-poll", value.poll.quiz ? [.init("quiz")] : []) { writer in
      writer.text(value.poll.question.text, entities: value.poll.question.entities)
      writer.element("ol") { writer in
        for answer in value.poll.answers {
          switch answer {
          case .pollAnswer(let option):
            var attributes: [Attribute] = []
            if let added = option.addedBy, added != author {
              attributes.append(.init("added-by", MarkupRenderer.peer(added)))
            }
            writer.element("li", attributes) {
              $0.text(option.text.text, entities: option.text.entities)
            }
          case .inputPollAnswer(let option):
            writer.element("li") { $0.text(option.text.text, entities: option.text.entities) }
          }
        }
      }
      if let solution = value.results.solution, !solution.isEmpty {
        writer.element("tg-poll-solution") {
          $0.text(solution, entities: value.results.solutionEntities ?? [])
        }
      }
    }
  }

  /// Only Telegram's preview is shown; the linked page was not fetched.
  private mutating func webPage(_ page: TL.WebPageType, depth: Int) {
    switch page {
    case .webPage(let value):
      let attributes = Self.attributes([
        ("url", value.url), ("site", value.siteName), ("title", value.title),
        ("author", value.author),
      ])
      if let description = value.description, !description.isEmpty {
        element("tg-preview", attributes) { $0.literal(description) }
      } else {
        void("tg-preview", attributes)
      }
    case .webPageEmpty(let value): void("tg-preview", Self.attributes([("url", value.url)]))
    case .webPagePending(let value): void("tg-preview", Self.attributes([("url", value.url)]))
    case .webPageNotModified: break
    }
  }

  mutating func replyMarkup(_ markup: TL.ReplyMarkupType) {
    switch markup {
    case .replyInlineMarkup(let value):
      for row in value.rows {
        element("tg-button-row") { writer in
          for button in row.buttons {
            writer.element("tg-button", Self.buttonAttributes(button.type)) {
              $0.literal(button.text)
            }
          }
        }
      }
    case .replyKeyboardMarkup(let value):
      element("tg-keyboard") { writer in
        for row in value.rows {
          writer.element("tg-button-row") { writer in
            for button in row.buttons {
              writer.element("tg-button", Self.keyboardAttributes(button.type)) {
                $0.literal(button.text)
              }
            }
          }
        }
      }
    case .replyKeyboardHide, .replyKeyboardForceReply: break
    }
  }

  /// Callback data is opaque and never rendered; no button is executed.
  static func buttonAttributes(_ type: TL.InlineButtonTypeType) -> [Attribute] {
    switch type {
    case .inlineButtonTypeUrl(let t): [.init("type", "url"), .init("url", t.url)]
    case .inlineButtonTypeUrlAuth(let t): [.init("type", "login_url"), .init("url", t.url)]
    case .inputInlineButtonTypeUrlAuth(let t): [.init("type", "login_url"), .init("url", t.url)]
    case .inlineButtonTypeWebView(let t): [.init("type", "web_app"), .init("url", t.url)]
    case .inlineButtonTypeCallback: [.init("type", "callback_data")]
    case .inlineButtonTypeGame: [.init("type", "callback_game")]
    case .inlineButtonTypeBuy: [.init("type", "pay")]
    case .inlineButtonTypeSwitchInline(let t):
      [.init("type", "switch_inline_query"), .init("query", t.query)]
    case .inlineButtonTypeUserProfile(let t):
      [.init("type", "url"), .init("url", "tg://user?id=\(t.userId)")]
    case .inputInlineButtonTypeUserProfile: [.init("type", "url")]
    case .inlineButtonTypeCopy(let t): [.init("type", "copy_text"), .init("text", t.copyText)]
    case .inlineButtonTypeDisabled: [.init("type", "disabled")]
    }
  }

  private static func keyboardAttributes(_ type: TL.ButtonTypeType) -> [Attribute] {
    switch type {
    case .buttonTypeDefault: [.init("type", "text")]
    case .buttonTypeRequestPhone: [.init("type", "request_contact")]
    case .buttonTypeRequestGeoLocation: [.init("type", "request_location")]
    case .buttonTypeRequestPoll: [.init("type", "request_poll")]
    case .buttonTypeRequestPeer, .inputButtonTypeRequestPeer: [.init("type", "request_chat")]
    case .buttonTypeSimpleWebView(let t): [.init("type", "web_app"), .init("url", t.url)]
    }
  }
}
