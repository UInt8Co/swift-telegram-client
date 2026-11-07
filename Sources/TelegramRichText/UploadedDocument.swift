import TelegramSchema

/// An upload result does not contain a reusable document.
public enum UploadedDocumentError: Error, Equatable, Sendable {
  /// A non-document media result or an empty document was returned.
  case missingDocument
}

/// A native document block with its matching input resource. Place this component
/// anywhere a block builder accepts content, then pass `document` in the
/// `documents` table to `RichMessage.inputMessage`. Placement and captions belong
/// to the caller; building the component performs no upload or access check.
public struct UploadedDocument: BlockContent {
  /// The input document reference to include with the containing message.
  public let document: TL.InputDocumentType
  /// The native attachment block, with the caller's caption and credit.
  public let blocks: [TL.PageBlockType]

  /// Accepts a completed document upload and caller-authored caption and credit.
  /// Missing/empty documents throw `UploadedDocumentError.missingDocument`.
  public init(_ media: TL.MessageMediaType, caption: some InlineContent,
    credit: some InlineContent = Text("")) throws {
    guard case .messageMediaDocument(let value) = media,
      let received = value.document, let input = ReceivedReferences.document(received),
      case .document(let resource) = received else { throw UploadedDocumentError.missingDocument }
    document = input
    blocks = [.pageBlockDocument(.init(documentId: resource.id,
      caption: .init(text: caption.richText, credit: credit.richText)))]
  }
}
