import Crypto
import MTProtoClientKit
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum SourceMedia: Equatable, Sendable {
  case photo(
    dcID: Int32, size: Int64, name: String, location: TL.InputFileLocationType,
    cachedBytes: Data?, spoiler: Bool)
  case document(
    dcID: Int32, size: Int64, name: String, mimeType: String,
    attributes: [TL.DocumentAttributeType], location: TL.InputFileLocationType,
    spoiler: Bool)

  var dcID: Int32 {
    switch self {
    case .photo(let dcID, _, _, _, _, _), .document(let dcID, _, _, _, _, _, _): dcID
    }
  }

  var size: Int64 {
    switch self {
    case .photo(_, let size, _, _, _, _), .document(_, let size, _, _, _, _, _): size
    }
  }

  var name: String {
    switch self {
    case .photo(_, _, let name, _, _, _), .document(_, _, let name, _, _, _, _): name
    }
  }

  var cachedBytes: Data? {
    guard case .photo(_, _, _, _, let bytes, _) = self else { return nil }
    return bytes
  }

  var location: TL.InputFileLocationType {
    switch self {
    case .photo(_, _, _, let location, _, _), .document(_, _, _, _, _, let location, _):
      location
    }
  }
}

extension SourceMedia {
  /// The same media with every attribute that names something only the source
  /// side can resolve replaced or dropped.
  ///
  /// A sticker's `stickerset` is the set it belongs to *there*, and a custom
  /// emoji is a document of a set the destination does not have; sent as they
  /// are, the destination refuses the upload. Emptying the set keeps the file a
  /// sticker — the destination takes it as one sent from a file rather than from
  /// a pack — and a custom emoji arrives as the plain document it is.
  public var portable: SourceMedia {
    guard
      case .document(
        let dcID, let size, let name, let mimeType, let attributes, let location,
        let spoiler) = self
    else { return self }
    let portableAttributes = attributes.compactMap { attribute -> TL.DocumentAttributeType? in
      switch attribute {
      case .documentAttributeSticker(let sticker):
        return .documentAttributeSticker(
          TL.DocumentAttributeSticker(
            mask: sticker.mask, alt: sticker.alt,
            stickerset: .inputStickerSetEmpty(TL.InputStickerSetEmpty()),
            maskCoords: sticker.maskCoords))
      case .documentAttributeCustomEmoji:
        return nil
      default:
        return attribute
      }
    }
    return .document(
      dcID: dcID, size: size, name: name, mimeType: mimeType,
      attributes: portableAttributes, location: location, spoiler: spoiler)
  }
}

public enum SourceMediaExtractor {
  public static func media(in update: TL.UpdateType) -> (messageID: Int32, media: SourceMedia)? {
    let message: TL.MessageType
    switch update {
    case .updateNewChannelMessage(let value): message = value.message
    case .updateNewMessage(let value): message = value.message
    default: return nil
    }
    guard case .message(let value) = message, let media = value.media,
      let source = source(media)
    else { return nil }
    return (value.id, source)
  }

  public static func source(_ media: TL.MessageMediaType) -> SourceMedia? {
    switch media {
    case .messageMediaPhoto(let value):
      guard case .photo(let photo) = value.photo,
        let candidate = largestPhotoSize(photo.sizes)
      else { return nil }
      return .photo(
        dcID: photo.dcId, size: candidate.size, name: "photo-\(photo.id).jpg",
        location: .inputPhotoFileLocation(
          TL.InputPhotoFileLocation(
            id: photo.id, accessHash: photo.accessHash,
            fileReference: photo.fileReference, thumbSize: candidate.type)),
        cachedBytes: candidate.cachedBytes, spoiler: value.spoiler)
    case .messageMediaDocument(let value):
      guard case .document(let document) = value.document, document.size > 0 else { return nil }
      let name =
        document.attributes.compactMap { attribute -> String? in
          guard case .documentAttributeFilename(let filename) = attribute else { return nil }
          return safeFileName(filename.fileName)
        }.first ?? "document-\(document.id)"
      return .document(
        dcID: document.dcId, size: document.size, name: name,
        mimeType: document.mimeType, attributes: document.attributes,
        location: .inputDocumentFileLocation(
          TL.InputDocumentFileLocation(
            id: document.id, accessHash: document.accessHash,
            fileReference: document.fileReference, thumbSize: "")),
        spoiler: value.spoiler)
    default:
      return nil
    }
  }

  private struct PhotoCandidate {
    var type: String
    var size: Int64
    var cachedBytes: Data?
  }

  private static func largestPhotoSize(_ sizes: [TL.PhotoSizeType]) -> PhotoCandidate? {
    sizes.compactMap { size -> PhotoCandidate? in
      switch size {
      case .photoSize(let value):
        return PhotoCandidate(type: value.type, size: Int64(value.size), cachedBytes: nil)
      case .photoCachedSize(let value):
        return PhotoCandidate(
          type: value.type, size: Int64(value.bytes.count), cachedBytes: value.bytes)
      case .photoSizeProgressive(let value):
        guard let bytes = value.sizes.max() else { return nil }
        return PhotoCandidate(type: value.type, size: Int64(bytes), cachedBytes: nil)
      default:
        return nil
      }
    }.filter { $0.size > 0 }.max { $0.size < $1.size }
  }

  private static func safeFileName(_ value: String) -> String? {
    let component = value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
    return component.flatMap { $0.isEmpty ? nil : $0 }
  }
}

public final class MediaTransfer: Sendable {
  private static let partSize: Int64 = 512 * 1024
  private static let bigFileThreshold: Int64 = 10 * 1024 * 1024

  private let source: TelegramClientPool
  private let destination: TLClient
  private let log: TelegramLog

  public init(
    source: TelegramClientPool, destination: TLClient, log: TelegramLog = .silent
  ) {
    self.source = source
    self.destination = destination
    self.log = log
  }

  /// Uploads belong to the account that will send or edit the message. Preserves
  /// the source pool while giving that account its own destination-side file
  /// references.
  public func sending(as client: TLClient) -> MediaTransfer {
    MediaTransfer(source: source, destination: client, log: log)
  }

  /// Copies the media of every update that carries some, keyed by the source
  /// message it came from. `excluding` names the source messages whose media the
  /// destination already holds — a sticker, say, is copied once into its set
  /// rather than once per message that sends it.
  public func transfer(
    updates: [TL.UpdateType], destination: ChannelReference, excluding: Set<Int32> = []
  ) async throws -> [(sourceMessageID: Int32, media: TL.InputMediaType)] {
    var result: [(sourceMessageID: Int32, media: TL.InputMediaType)] = []
    var seen: Set<Int32> = []
    for update in updates {
      guard let source = SourceMediaExtractor.media(in: update),
        !excluding.contains(source.messageID), seen.insert(source.messageID).inserted
      else { continue }
      log.debug("transferring media for source message \(source.messageID)")
      let media = try await transfer(source.media, destination: destination)
      result.append((sourceMessageID: source.messageID, media: media))
    }
    return result
  }

  /// Copies one source document into the account's own storage, where a sticker
  /// set can take it. Naming `inputPeerSelf` is what keeps the bytes on the
  /// account's own track rather than a channel's.
  public func uploadSticker(_ source: SourceMedia) async throws -> TL.InputDocumentType {
    let stored = try await upload(source, to: .inputPeerSelf(TL.InputPeerSelf()))
    guard case .messageMediaDocument(let value) = stored,
      case .document(let document) = value.document
    else { throw MediaTransferError.invalidResult }
    return .inputDocument(
      TL.InputDocument(
        id: document.id, accessHash: document.accessHash,
        fileReference: document.fileReference))
  }

  /// Copies one source object into the destination and names it the way a
  /// message there refers to it — which is what a send, or an edit that replaces
  /// a message's media, is given.
  public func transfer(_ source: SourceMedia, destination: ChannelReference) async throws
    -> TL.InputMediaType
  {
    try storedInputMedia(try await upload(source, to: destination.inputPeer))
  }

  /// Streams one source object into the destination and finalizes it there, in
  /// 512 KB parts.
  private func upload(_ source: SourceMedia, to peer: TL.InputPeerType) async throws
    -> TL.MessageMediaType
  {
    guard source.size > 0 else { throw MediaTransferError.invalidSize(source.size) }
    let totalParts64 = (source.size + Self.partSize - 1) / Self.partSize
    guard totalParts64 <= Int64(Int32.max) else {
      throw MediaTransferError.tooManyParts(totalParts64)
    }
    let totalParts = Int32(totalParts64)
    let fileID = Int64.random(in: 1...Int64.max)
    let isBig = source.size > Self.bigFileThreshold
    var md5 = Insecure.MD5()
    var part: Int32 = 0

    if let bytes = source.cachedBytes {
      guard Int64(bytes.count) == source.size else {
        throw MediaTransferError.incomplete(expected: source.size, actual: Int64(bytes.count))
      }
      md5.update(data: bytes)
      try await save(bytes, fileID: fileID, part: part, totalParts: totalParts, isBig: isBig)
      part += 1
    } else {
      var visitedDCs: Set<Int32> = [source.dcID]
      var sourceConnection = try await self.source.connection(for: source.dcID)
      var offset: Int64 = 0
      while offset < source.size {
        let response: TL.Upload.FileType
        do {
          // A part is a read: a source that times out on one is asked again
          // rather than losing the whole transfer (`ServerTimeout`).
          response = try await ServerTimeout.repeating("upload.getFile", log: log) {
            try await sourceConnection.api.invoke(
              TL.Upload.GetFile(
                location: source.location, offset: offset, limit: Int32(Self.partSize)))
          }
        } catch {
          // FILE_MIGRATE_X names the DC that actually holds the file; the same
          // DC twice is a loop.
          guard case .migrate(let dcID)? = MTProtoDirective(error),
            visitedDCs.insert(dcID).inserted
          else { throw error }
          log.info("the source holds this file on DC \(dcID); switching")
          sourceConnection = try await self.source.connection(for: dcID)
          continue
        }
        let bytes: Data
        switch response {
        case .file(let file): bytes = file.bytes
        case .fileCdnRedirect(let redirect):
          throw MediaTransferError.cdnRedirect(redirect.dcId)
        }
        guard !bytes.isEmpty else {
          throw MediaTransferError.incomplete(expected: source.size, actual: offset)
        }
        let remaining = source.size - offset
        guard Int64(bytes.count) <= remaining else {
          throw MediaTransferError.incomplete(
            expected: source.size, actual: offset + Int64(bytes.count))
        }
        md5.update(data: bytes)
        try await save(
          bytes, fileID: fileID, part: part, totalParts: totalParts, isBig: isBig)
        offset += Int64(bytes.count)
        part += 1
      }
      guard offset == source.size else {
        throw MediaTransferError.incomplete(expected: source.size, actual: offset)
      }
    }
    guard part == totalParts else {
      throw MediaTransferError.partCount(expected: totalParts, actual: part)
    }

    let inputFile: TL.InputFileType =
      if isBig {
        .inputFileBig(TL.InputFileBig(id: fileID, parts: totalParts, name: source.name))
      } else {
        .inputFile(
          TL.InputFile(
            id: fileID, parts: totalParts, name: source.name,
            md5Checksum: Self.hex(md5.finalize())))
      }
    let uploaded: TL.InputMediaType
    switch source {
    case .photo(_, _, _, _, _, let spoiler):
      uploaded = .inputMediaUploadedPhoto(
        TL.InputMediaUploadedPhoto(spoiler: spoiler, file: inputFile))
    case .document(_, _, _, let mimeType, let attributes, _, let spoiler):
      uploaded = .inputMediaUploadedDocument(
        TL.InputMediaUploadedDocument(
          spoiler: spoiler, file: inputFile, mimeType: mimeType, attributes: attributes))
    }
    return try await FloodWait.honoring("messages.uploadMedia", log: log) {
      try await destination.invoke(TL.Messages.UploadMedia(peer: peer, media: uploaded))
    }
  }

  private func save(
    _ bytes: Data, fileID: Int64, part: Int32, totalParts: Int32, isBig: Bool
  ) async throws {
    let saved = try await FloodWait.honoring("upload.saveFilePart", log: log) {
      if isBig {
        try await destination.invoke(
          TL.Upload.SaveBigFilePart(
            fileId: fileID, filePart: part, fileTotalParts: totalParts, bytes: bytes))
      } else {
        try await destination.invoke(
          TL.Upload.SaveFilePart(fileId: fileID, filePart: part, bytes: bytes))
      }
    }
    guard saved else { throw MediaTransferError.partRejected(part) }
  }

  private func storedInputMedia(_ media: TL.MessageMediaType) throws -> TL.InputMediaType {
    switch media {
    case .messageMediaPhoto(let value):
      guard case .photo(let photo) = value.photo else { throw MediaTransferError.invalidResult }
      return .inputMediaPhoto(
        TL.InputMediaPhoto(
          spoiler: value.spoiler,
          id: .inputPhoto(
            TL.InputPhoto(
              id: photo.id, accessHash: photo.accessHash,
              fileReference: photo.fileReference))))
    case .messageMediaDocument(let value):
      guard case .document(let document) = value.document else {
        throw MediaTransferError.invalidResult
      }
      return .inputMediaDocument(
        TL.InputMediaDocument(
          spoiler: value.spoiler,
          id: .inputDocument(
            TL.InputDocument(
              id: document.id, accessHash: document.accessHash,
              fileReference: document.fileReference))))
    default:
      throw MediaTransferError.invalidResult
    }
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { byte in
      let value = String(byte, radix: 16)
      return value.count == 1 ? "0\(value)" : value
    }.joined()
  }
}

public enum MediaTransferError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidSize(Int64)
  case tooManyParts(Int64)
  case cdnRedirect(Int32)
  case incomplete(expected: Int64, actual: Int64)
  case partCount(expected: Int32, actual: Int32)
  case partRejected(Int32)
  case invalidResult

  public var description: String {
    switch self {
    case .invalidSize(let size): "source media has invalid size \(size)"
    case .tooManyParts(let count): "source media needs too many upload parts: \(count)"
    case .cdnRedirect(let dc): "media was redirected to unsupported CDN DC \(dc)"
    case .incomplete(let expected, let actual):
      "source media is incomplete: expected \(expected) bytes, received \(actual)"
    case .partCount(let expected, let actual):
      "media upload part count differs: expected \(expected), sent \(actual)"
    case .partRejected(let part): "the destination rejected media upload part \(part)"
    case .invalidResult: "the destination returned an unsupported uploaded-media result"
    }
  }
}
