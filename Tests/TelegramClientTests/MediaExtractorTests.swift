import TelegramSchema
import Testing

@testable import TelegramClient

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct MediaExtractorTests {
  @Test func choosesLargestPhotoRendition() throws {
    let photo = TL.Photo(
      id: 10, accessHash: 11, fileReference: Data([1]), date: 12,
      sizes: [
        .photoSize(TL.PhotoSize(type: "m", w: 100, h: 100, size: 1_000)),
        .photoSizeProgressive(
          TL.PhotoSizeProgressive(type: "y", w: 1_000, h: 1_000, sizes: [10_000, 50_000])),
      ], dcId: 4)
    let source = SourceMediaExtractor.source(
      .messageMediaPhoto(TL.MessageMediaPhoto(spoiler: true, photo: .photo(photo))))
    guard case .photo(let dc, let size, let name, let location, _, let spoiler) = source else {
      Issue.record("photo was not extractable")
      return
    }
    #expect(dc == 4)
    #expect(size == 50_000)
    #expect(name == "photo-10.jpg")
    #expect(spoiler)
    guard case .inputPhotoFileLocation(let value) = location else {
      Issue.record("wrong photo location")
      return
    }
    #expect(value.thumbSize == "y")
  }

  @Test func keepsDocumentMetadataAndSanitizesName() {
    let attributes: [TL.DocumentAttributeType] = [
      .documentAttributeFilename(TL.DocumentAttributeFilename(fileName: "path/to/movie.mp4")),
      .documentAttributeVideo(
        TL.DocumentAttributeVideo(
          supportsStreaming: true, duration: 3, w: 640, h: 480)),
    ]
    let document = TL.Document(
      id: 20, accessHash: 21, fileReference: Data([2]), date: 22,
      mimeType: "video/mp4", size: 60_000, dcId: 5, attributes: attributes)
    let source = SourceMediaExtractor.source(
      .messageMediaDocument(
        TL.MessageMediaDocument(document: .document(document))))
    guard case .document(let dc, let size, let name, let mime, let got, _, _) = source else {
      Issue.record("document was not extractable")
      return
    }
    #expect(dc == 5)
    #expect(size == 60_000)
    #expect(name == "movie.mp4")
    #expect(mime == "video/mp4")
    #expect(got == attributes)
  }
}
