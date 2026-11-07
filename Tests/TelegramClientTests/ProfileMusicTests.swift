import TelegramClient
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct ProfileMusicTests {
  @Test func firstSavedTrackUsesOnlyNamedAudioFields() throws {
    let document = musicDocument()
    let full = TL.UserFull(
      id: 7, settings: .init(), notifySettings: .init(), commonChatsCount: 0, savedMusic: document)
    let projected = try #require(ProfileMusic(full))
    #expect(projected.documentID == 1234)
    #expect(
      projected.title == "A song" && projected.performer == "Artist"
        && projected.filename == "recording.mp3")
  }

  @Test func absentVoiceNonAudioAndZeroIDsHaveNoProjection() {
    for document: TL.DocumentType? in [
      nil, .documentEmpty(.init(id: 1234)), musicDocument(voice: true),
      musicDocument(audio: false), musicDocument(id: 0),
    ] {
      let full = TL.UserFull(
        id: 7, settings: .init(), notifySettings: .init(), commonChatsCount: 0, savedMusic: document
      )
      #expect(ProfileMusic(full) == nil)
    }
  }

  @Test func missingOrEmptyAudioFieldsRetainDocumentIdentity() throws {
    guard case .document(let document) = musicDocument(title: "", performer: nil, filename: nil)
    else { return }
    let projected = try #require(ProfileMusic(document))
    #expect(projected.documentID == 1234)
    #expect(projected.title == nil && projected.performer == nil && projected.filename == nil)
  }
}

private func musicDocument(
  id: Int64 = 1234, title: String? = "A song", performer: String? = "Artist",
  filename: String? = "recording.mp3", voice: Bool = false, audio: Bool = true
) -> TL.DocumentType {
  var attributes: [TL.DocumentAttributeType] = []
  if audio {
    attributes.append(
      .documentAttributeAudio(.init(voice: voice, duration: 60, title: title, performer: performer))
    )
  }
  if let filename { attributes.append(.documentAttributeFilename(.init(fileName: filename))) }
  return .document(
    .init(
      id: id, accessHash: 1, fileReference: Data([1]), date: 1,
      mimeType: "audio/mpeg", size: 100, dcId: 1, attributes: attributes))
}
