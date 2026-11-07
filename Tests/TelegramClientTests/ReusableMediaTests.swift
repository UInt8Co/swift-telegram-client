#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import TelegramSchema
import TelegramClient

@Suite struct ReusableMediaTests {

  private let reference = Data([1, 2, 3])
  private var photo: TL.Photo { .init(id: 11, accessHash: 22, fileReference: reference, date: 3, sizes: [], dcId: 2) }
  private var document: TL.DocumentType { .document(.init(id: 33, accessHash: 44, fileReference: reference,
    date: 1, mimeType: "video/mp4", size: 100, dcId: 2, attributes: [])) }
  @Test func photoAndDocumentReferencesPreserveMediaOptions() throws {
    let photoInput = try ReusableMedia.convert(.messageMediaPhoto(.init(spoiler: true, livePhoto: true,
      photo: .photo(photo), ttlSeconds: 30, video: document))).get()
    guard case .inputMediaPhoto(let copy) = photoInput else { Issue.record("Missing photo"); return }
    #expect(copy.id == .inputPhoto(.init(id: 11, accessHash: 22, fileReference: reference)))
    #expect(copy.spoiler && copy.livePhoto)
    #expect(copy.ttlSeconds == nil)
    #expect(copy.video == MediaReferences.document(document))
    let documentInput = try ReusableMedia.convert(.messageMediaDocument(.init(spoiler: true,
      document: document, videoCover: .photo(photo), videoTimestamp: 8))).get()
    guard case .inputMediaDocument(let copied) = documentInput else { Issue.record("Missing document"); return }
    #expect(copied.id == .inputDocument(.init(id: 33, accessHash: 44, fileReference: reference)))
    #expect(copied.videoCover == copy.id && copied.videoTimestamp == 8 && copied.spoiler)
    #expect(try TL.InputMediaType(tlData: documentInput.tlSerialized()) == documentInput)
  }
  @Test func incompleteAndUnsupportedAreDistinct() {
    for media: TL.MessageMediaType in [.messageMediaPhoto(.init()),
      .messageMediaPhoto(.init(livePhoto: true, photo: .photo(photo))),
      .messageMediaDocument(.init(document: .documentEmpty(.init(id: 1)))),
      .messageMediaGeo(.init(geo: .geoPointEmpty(.init()))),
      .messageMediaWebPage(.init(webpage: .webPageNotModified(.init())))] {
      #expect(throws: MediaReuseError.incomplete) { try ReusableMedia.convert(media).get() }
    }
    #expect(throws: MediaReuseError.unsupported) {
      try ReusableMedia.convert(.messageMediaDice(.init(value: 1, emoticon: "🎲"))).get()
    }
  }
  @Test func contactsLocationsVenuesAndWebpages() throws {
    let point = TL.GeoPointType.geoPoint(.init(long: 1.25, lat: 2.5, accessHash: 3, accuracyRadius: 4))
    let inputPoint = TL.InputGeoPointType.inputGeoPoint(.init(lat: 2.5, long: 1.25, accuracyRadius: 4))
    #expect(try ReusableMedia.convert(.messageMediaContact(.init(phoneNumber: "123", firstName: "A",
      lastName: "B", vcard: "card", userId: 5))).get()
      == .inputMediaContact(.init(phoneNumber: "123", firstName: "A", lastName: "B", vcard: "card")))
    #expect(try ReusableMedia.convert(.messageMediaGeo(.init(geo: point))).get() == .inputMediaGeoPoint(.init(geoPoint: inputPoint)))
    #expect(try ReusableMedia.convert(.messageMediaVenue(.init(geo: point, title: "Place", address: "Street",
      provider: "provider", venueId: "venue", venueType: "park"))).get()
      == .inputMediaVenue(.init(geoPoint: inputPoint, title: "Place", address: "Street", provider: "provider", venueId: "venue", venueType: "park")))
    for page: TL.WebPageType in [.webPageEmpty(.init(id: 1, url: "https://example.com")),
      .webPagePending(.init(id: 1, url: "https://example.com", date: 1)),
      .webPage(.init(id: 1, url: "https://example.com", displayUrl: "example.com", hash: 0))] {
      #expect(try ReusableMedia.convert(.messageMediaWebPage(.init(forceLargeMedia: true, webpage: page))).get()
        == .inputMediaWebPage(.init(forceLargeMedia: true, url: "https://example.com")))
    }
  }
}
