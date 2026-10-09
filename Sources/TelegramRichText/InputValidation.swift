import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum RichMessageValidationError: Error, Equatable, Sendable {
  case unsupportedRichText(String)
  case nestingTooDeep
  case tooManyBlocks
  case textTooLong
  case tooManyAttachments
  case tooManyTableColumns
}

extension RichMessage {
  /// The sending boundary for both authored messages and copied native blocks.
  /// Server-generated entities are converted to input text; unsupported
  /// formatting and exceeded Telegram limits throw before a request is sent.
  public static func inputMessage(
    blocks: [TL.PageBlockType], rtl: Bool = false,
    photos: [TL.InputPhotoType]? = nil,
    documents: [TL.InputDocumentType]? = nil,
    users: [TL.InputUserType]? = nil
  ) throws -> TL.InputRichMessageType {
    guard (photos?.count ?? 0) + (documents?.count ?? 0) <= 50 else {
      throw RichMessageValidationError.tooManyAttachments
    }
    let input = inputBlocks(blocks)
    var validation = InputValidation()
    try validation.visit(input)
    return .inputRichMessage(
      .init(
        rtl: rtl, noautolink: false, blocks: input,
        photos: photos, documents: documents, users: users))
  }
}

/// https://core.telegram.org/bots/api#rich-message-limits
/// Count semantic TL nodes, never the generated structs or flag wrappers.
private struct InputValidation {
  var blocks = 0
  var characters = 0

  mutating func visit(_ value: Any, depth: Int = 0) throws {
    var nextDepth = depth
    if let block = value as? TL.PageBlockType {
      blocks += 1
      nextDepth += 1
      if case .pageBlockMath(let math) = block { characters += math.source.unicodeScalars.count }
    } else if value is TL.PageListItemType || value is TL.PageListOrderedItemType
      || value is TL.PageTableRow
    {
      blocks += 1
      nextDepth += 1
    } else if let rich = value as? TL.RichTextType {
      switch rich {
      case .textEmpty, .textImage: break
      case .textPlain(let text): characters += text.text.unicodeScalars.count
      case .textMath(let math): characters += math.source.unicodeScalars.count
      case .textCustomEmoji(let emoji): characters += emoji.alt.unicodeScalars.count
      case .textDiff: throw RichMessageValidationError.unsupportedRichText("textDiff")
      // These are removed by inputBlocks. Keep them explicitly forbidden
      // here so a future conversion change cannot leak them to Telegram.
      case .textMention: throw RichMessageValidationError.unsupportedRichText("textMention")
      case .textHashtag: throw RichMessageValidationError.unsupportedRichText("textHashtag")
      case .textBotCommand: throw RichMessageValidationError.unsupportedRichText("textBotCommand")
      case .textCashtag: throw RichMessageValidationError.unsupportedRichText("textCashtag")
      case .textAutoUrl: throw RichMessageValidationError.unsupportedRichText("textAutoUrl")
      case .textAutoEmail: throw RichMessageValidationError.unsupportedRichText("textAutoEmail")
      case .textAutoPhone: throw RichMessageValidationError.unsupportedRichText("textAutoPhone")
      case .textBankCard: throw RichMessageValidationError.unsupportedRichText("textBankCard")
      default: nextDepth += 1
      }
    }
    if let row = value as? TL.PageTableRow {
      let columns = row.cells.reduce(Int64(0)) { $0 + max(1, Int64($1.colspan ?? 1)) }
      guard columns <= 20 else { throw RichMessageValidationError.tooManyTableColumns }
    }
    // Plain/empty text is a leaf, not another formatting level. Live MTProto
    // accepts a paragraph with 15 nested bold nodes and rejects 16.
    guard nextDepth <= 16 else { throw RichMessageValidationError.nestingTooDeep }
    guard blocks <= 500 else { throw RichMessageValidationError.tooManyBlocks }
    guard characters <= 32_768 else { throw RichMessageValidationError.textTooLong }
    if value is String || value is Data { return }
    for child in Mirror(reflecting: value).children { try visit(child.value, depth: nextDepth) }
  }
}
