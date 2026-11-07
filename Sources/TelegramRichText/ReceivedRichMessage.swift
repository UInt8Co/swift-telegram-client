import TelegramSchema

/// Received content lacks a complete set of reusable resources.
public enum ReceivedRichMessageError: Error, Equatable, Sendable {
  /// A partial message or empty photo/document cannot be copied losslessly.
  case incomplete
}

extension RichMessage {
  /// Converts complete received blocks and resource tables into validated input.
  /// Rejects partial messages and empty resource constructors before conversion;
  /// unsupported blocks/text throw `RichMessageValidationError`. Resource order,
  /// IDs, hashes, file-reference bytes, and RTL are retained. This does not fetch
  /// missing resources or verify server access to the resulting references.
  public static func inputMessage(received: TL.RichMessage) throws -> TL.InputRichMessageType {
    let photos = received.photos.compactMap { photo -> TL.InputPhotoType? in
      guard case .photo(let value) = photo else { return nil }
      return MediaReferences.photo(value)
    }
    let documents = received.documents.compactMap(MediaReferences.document)
    guard !received.part, photos.count == received.photos.count,
      documents.count == received.documents.count else { throw ReceivedRichMessageError.incomplete }
    return try inputMessage(blocks: received.blocks, rtl: received.rtl,
      photos: photos.isEmpty ? nil : photos, documents: documents.isEmpty ? nil : documents)
  }
}
