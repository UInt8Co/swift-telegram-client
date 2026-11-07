import TelegramSchema

/// Input references for complete received resources, preserving IDs, access
/// hashes and file-reference bytes. Mirrors TelegramClient's `MediaReferences`,
/// which this module cannot import.
enum ReceivedReferences {
  static func photo(_ value: TL.Photo) -> TL.InputPhotoType {
    .inputPhoto(.init(id: value.id, accessHash: value.accessHash, fileReference: value.fileReference))
  }

  static func document(_ value: TL.DocumentType) -> TL.InputDocumentType? {
    guard case .document(let document) = value else { return nil }
    return .inputDocument(.init(id: document.id, accessHash: document.accessHash, fileReference: document.fileReference))
  }
}
