import TelegramSchema

/// Renders received Telegram message content as compact markup in the style of
/// the Bot API's rich HTML (https://core.telegram.org/bots/api#rich-html-style).
/// It is the reverse of Telegram's HTML parser: entity offsets, constructor
/// trees and transport fields become nested tags that a person, or a language
/// model, can read directly.
///
/// Telegram's own tags are used where they exist. Content Telegram has no HTML
/// for (stickers, polls, contacts, link previews) uses `tg-*` tags. Text and
/// attribute values are escaped, so participant text never becomes markup.
/// Opaque payloads (callback data, file references, access hashes, binary
/// fields) and media contents are never part of the output.
public struct MarkupRenderer: Sendable {
  /// Display metadata for a sticker or custom-emoji pack.
  public struct Pack: Equatable, Sendable {
    public var title: String
    public var shortName: String
    public init(title: String, shortName: String) {
      self.title = title
      self.shortName = shortName
    }
  }

  public struct Output: Equatable, Sendable {
    public var markup: String
    /// False when an invalid entity range or excessive nesting meant some
    /// content could not be rendered.
    public var isComplete: Bool
    public init(markup: String, isComplete: Bool) {
      self.markup = markup
      self.isComplete = isComplete
    }
  }

  /// Custom emoji document ID to its pack.
  public var customEmoji: [Int64: Pack]
  /// Sticker set ID to its pack. Short-name references resolve through the
  /// same values.
  public var stickerSets: [Int64: Pack]
  public var maximumDepth: Int

  public init(
    customEmoji: [Int64: Pack] = [:], stickerSets: [Int64: Pack] = [:], maximumDepth: Int = 24
  ) {
    self.customEmoji = customEmoji
    self.stickerSets = stickerSets
    self.maximumDepth = maximumDepth
  }

  /// Text with entities, rich-message blocks, media, then the reply markup.
  public func render(_ message: TL.Message) -> Output {
    run { writer in
      var parts: [String] = []
      func part(_ body: (inout Writer) -> Void) {
        let start = writer.output.endIndex
        body(&writer)
        let added = String(writer.output[start...])
        writer.output.removeSubrange(start...)
        if !added.isEmpty { parts.append(added) }
      }
      part { $0.text(message.message, entities: message.entities ?? []) }
      if let rich = message.richMessage { part { $0.blocks(rich.blocks, depth: 0) } }
      if let media = message.media { part { $0.media(media, author: message.fromId, depth: 0) } }
      if let markup = message.replyMarkup { part { $0.replyMarkup(markup) } }
      writer.output = parts.joined(separator: "\n")
    }
  }

  public func render(text: String, entities: [TL.MessageEntityType]) -> Output {
    run { $0.text(text, entities: entities) }
  }

  public func render(_ blocks: [TL.PageBlockType]) -> Output {
    run { $0.blocks(blocks, depth: 0) }
  }

  public func render(_ text: TL.RichTextType) -> Output {
    run { $0.rich(text, depth: 0) }
  }

  public func render(_ media: TL.MessageMediaType, author: TL.PeerType? = nil) -> Output {
    run { $0.media(media, author: author, depth: 0) }
  }

  public func render(_ markup: TL.ReplyMarkupType) -> Output {
    run { $0.replyMarkup(markup) }
  }

  /// Escapes text content (`&`, `<`, `>`) or, with `quote`, an attribute value.
  public static func escape(_ value: String, quote: Bool = false) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"" where quote: result += "&quot;"
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  /// The text of rendered markup without its tags or attributes. Exact for
  /// this renderer's output, whose text and attributes never hold a raw `<`.
  public static func visibleText(_ markup: String) -> String {
    var result = ""
    var inTag = false
    var entity: String?
    for character in markup {
      if inTag {
        if character == ">" { inTag = false }
        continue
      }
      if var pending = entity {
        pending.append(character)
        if character == ";" {
          result += ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\""][pending] ?? pending
          entity = nil
        } else if pending.count > 6 {
          result += pending
          entity = nil
        } else {
          entity = pending
        }
        continue
      }
      switch character {
      case "<": inTag = true
      case "&": entity = "&"
      default: result.append(character)
      }
    }
    return result + (entity ?? "")
  }

  /// Peer IDs as `user:`, `chat:` or `channel:` followed by the bare ID.
  public static func peer(_ peer: TL.PeerType) -> String {
    switch peer {
    case .peerUser(let value): "user:\(value.userId)"
    case .peerChat(let value): "chat:\(value.chatId)"
    case .peerChannel(let value): "channel:\(value.channelId)"
    }
  }

  private func run(_ body: (inout Writer) -> Void) -> Output {
    var writer = Writer(renderer: self)
    body(&writer)
    return .init(markup: writer.output, isComplete: writer.complete)
  }
}

/// An attribute with no value renders as a bare boolean attribute.
struct Attribute {
  var name: String
  var value: String?
  init(_ name: String, _ value: String? = nil) {
    self.name = name
    self.value = value
  }
}

struct Writer {
  let renderer: MarkupRenderer
  var output = ""
  var complete = true

  mutating func literal(_ value: String) { output += MarkupRenderer.escape(value) }

  static func openTag(_ name: String, _ attributes: [Attribute] = []) -> String {
    var tag = "<" + name
    for attribute in attributes {
      tag += " " + attribute.name
      if let value = attribute.value {
        tag += "=\"" + MarkupRenderer.escape(value, quote: true) + "\""
      }
    }
    return tag + ">"
  }

  mutating func void(_ name: String, _ attributes: [Attribute] = []) {
    output += String(Self.openTag(name, attributes).dropLast()) + "/>"
  }

  mutating func element(
    _ name: String, _ attributes: [Attribute] = [], _ body: (inout Writer) -> Void
  ) {
    output += Self.openTag(name, attributes)
    body(&self)
    output += "</\(name)>"
  }

  /// Omit empty optional attributes rather than emitting `name=""`.
  static func attributes(_ pairs: [(String, String?)]) -> [Attribute] {
    pairs.compactMap { name, value in value.flatMap { $0.isEmpty ? nil : Attribute(name, $0) } }
  }

  mutating func guardDepth(_ depth: Int) -> Bool {
    if depth >= renderer.maximumDepth {
      complete = false
      return false
    }
    return true
  }

  func packAttributes(_ pack: MarkupRenderer.Pack?) -> [Attribute] {
    guard let pack else { return [] }
    return Self.attributes([("pack", pack.title), ("pack-name", pack.shortName)])
  }

  func pack(_ reference: TL.InputStickerSetType) -> MarkupRenderer.Pack? {
    switch reference {
    case .inputStickerSetID(let set): return renderer.stickerSets[set.id]
    case .inputStickerSetShortName(let set):
      let name = set.shortName.lowercased()
      return renderer.stickerSets.values.first { $0.shortName.lowercased() == name }
    default: return nil
    }
  }
}
