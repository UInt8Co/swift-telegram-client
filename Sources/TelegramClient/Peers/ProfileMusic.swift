import TelegramSchema

/// Display metadata from a single saved audio document, not a playlist or authorship claim.
public struct ProfileMusic: Equatable, Sendable {
  /// Nonzero Telegram document identity.
  public var documentID: Int64
  /// Last audio attribute's nonempty title, if supplied.
  public var title: String?
  /// Last audio attribute's nonempty performer, if supplied.
  public var performer: String?
  /// Last filename attribute's nonempty filename, if supplied.
  public var filename: String?

  /// Projects the current first saved track of a full-user response.
  /// Nil means absent or unusable audio; it does not describe unobserved playlist entries.
  public init?(_ fullUser: TL.UserFull) {
    guard case .document(let document)? = fullUser.savedMusic else { return nil }
    self.init(document)
  }

  /// Rejects zero IDs, non-audio documents and any voice attribute. Only named audio
  /// and filename fields are read; MIME types, credentials and waveform are ignored.
  public init?(_ document: TL.Document) {
    let audio = document.attributes.compactMap { attribute -> TL.DocumentAttributeAudio? in
      if case .documentAttributeAudio(let audio) = attribute { return audio }
      return nil
    }
    guard document.id != 0, !audio.isEmpty, !audio.contains(where: \.voice) else { return nil }
    documentID = document.id
    for attribute in document.attributes {
      switch attribute {
      case .documentAttributeAudio(let audio):
        title = audio.title
        performer = audio.performer
      case .documentAttributeFilename(let name): filename = name.fileName
      default: break
      }
    }
    if title?.isEmpty == true { title = nil }
    if performer?.isEmpty == true { performer = nil }
    if filename?.isEmpty == true { filename = nil }
  }
}
