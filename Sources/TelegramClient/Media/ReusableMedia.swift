import TelegramSchema

/// Why a received media object cannot be represented by a reusable reference.
public enum MediaReuseError: Error, Equatable, Sendable {
  /// This media constructor has no conversion here.
  case unsupported
  /// A supported constructor lacks a required photo, document, point, or URL.
  case incomplete
}

/// Converts existing server resources without uploading or checking access.
/// File references may expire; success does not guarantee a subsequent send.
public enum ReusableMedia {
  /// Preserves spoilers, live-photo video, video covers/timestamps, contacts,
  /// coordinates, venue fields and webpage sizing. Received TTLs are deliberately
  /// omitted. Missing optional covers are omitted; live photos require video.
  public static func convert(_ media: TL.MessageMediaType) -> Result<TL.InputMediaType, MediaReuseError> {
    switch media {
    case .messageMediaPhoto(let value):
      guard case .photo(let photo) = value.photo else { return .failure(.incomplete) }
      let video = value.video.flatMap(MediaReferences.document)
      guard !value.livePhoto || video != nil else { return .failure(.incomplete) }
      return .success(.inputMediaPhoto(.init(spoiler: value.spoiler, livePhoto: value.livePhoto,
        id: MediaReferences.photo(photo), video: video)))
    case .messageMediaDocument(let value):
      guard let document = value.document.flatMap(MediaReferences.document) else { return .failure(.incomplete) }
      let cover: TL.InputPhotoType?
      if case .photo(let photo) = value.videoCover { cover = MediaReferences.photo(photo) } else { cover = nil }
      return .success(.inputMediaDocument(.init(spoiler: value.spoiler, id: document,
        videoCover: cover, videoTimestamp: value.videoTimestamp)))
    case .messageMediaContact(let value):
      return .success(.inputMediaContact(.init(phoneNumber: value.phoneNumber, firstName: value.firstName,
        lastName: value.lastName, vcard: value.vcard)))
    case .messageMediaGeo(let value):
      guard let point = inputGeo(value.geo) else { return .failure(.incomplete) }
      return .success(.inputMediaGeoPoint(.init(geoPoint: point)))
    case .messageMediaVenue(let value):
      guard let point = inputGeo(value.geo) else { return .failure(.incomplete) }
      return .success(.inputMediaVenue(.init(geoPoint: point, title: value.title, address: value.address,
        provider: value.provider, venueId: value.venueId, venueType: value.venueType)))
    case .messageMediaWebPage(let value):
      let url: String?
      switch value.webpage {
      case .webPage(let page): url = page.url
      case .webPagePending(let page): url = page.url
      case .webPageEmpty(let page): url = page.url
      case .webPageNotModified: url = nil
      }
      guard let url else { return .failure(.incomplete) }
      return .success(.inputMediaWebPage(.init(forceLargeMedia: value.forceLargeMedia,
        forceSmallMedia: value.forceSmallMedia, url: url)))
    default: return .failure(.unsupported)
    }
  }


  private static func inputGeo(_ value: TL.GeoPointType) -> TL.InputGeoPointType? {
    guard case .geoPoint(let point) = value else { return nil }
    return .inputGeoPoint(.init(lat: point.lat, long: point.long, accuracyRadius: point.accuracyRadius))
  }
}
