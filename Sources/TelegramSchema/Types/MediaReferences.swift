// Handwritten resource conversions shared by client and rich-message APIs.
import TelegramSchemaSupport

/// Converts complete received resources to input references without network IO.
/// References retain their bytes verbatim and may subsequently expire or be
/// inaccessible to another account; conversion does not verify access.
public enum MediaReferences {
  /// Returns a photo reference with the received ID, hash, and file reference.
  public static func photo(_ value: TL.Photo) -> TL.InputPhotoType {
    .inputPhoto(.init(id: value.id, accessHash: value.accessHash, fileReference: value.fileReference))
  }

  /// Returns nil for an empty document; otherwise preserves ID, hash, and bytes.
  public static func document(_ value: TL.DocumentType) -> TL.InputDocumentType? {
    guard case .document(let document) = value else { return nil }
    return .inputDocument(.init(id: document.id, accessHash: document.accessHash, fileReference: document.fileReference))
  }
}
