#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import TelegramSchema
import TelegramRichText

@Suite struct ReceivedContentTests {

  private var document: TL.DocumentType { .document(.init(id: 33, accessHash: 44, fileReference: Data([2]),
    date: 1, mimeType: "text/plain", size: 100, dcId: 2, attributes: [])) }
  @Test func receivedResourcesAndEntitiesBecomeInput() throws {
    let hashtag = TL.RichTextType.textHashtag(.init(text: Text("#example").richText))
    let rich = TL.RichMessage(rtl: true, blocks: [
      .pageBlockDetails(.init(blocks: [
        .pageBlockParagraph(.init(text: hashtag)),
        .pageBlockDocument(.init(documentId: 33, caption: .init(text: hashtag, credit: .textEmpty(.init()))))
      ], title: hashtag))],
      photos: [.photo(.init(id: 11, accessHash: 22, fileReference: Data([1]), date: 1, sizes: [], dcId: 2))],
      documents: [document])
    let converted = try RichMessage.inputMessage(received: rich)
    guard case .inputRichMessage(let input) = converted,
       case .pageBlockDetails(let details) = input.blocks.first else { Issue.record("Missing content"); return }
    #expect(input.rtl && !input.noautolink)
    #expect(details.title == Text("#example").richText)
    #expect(input.photos == [.inputPhoto(.init(id: 11, accessHash: 22, fileReference: Data([1])))])
    #expect(input.documents == [.inputDocument(.init(id: 33, accessHash: 44, fileReference: Data([2])))])
    #expect(try TL.InputRichMessageType(tlData: converted.tlSerialized()) == converted)
  }
  @Test func partialResourcesAndUnsupportedTextAreRejected() {
    let blocks = Paragraph("Hello").blocks
    for rich in [TL.RichMessage(part: true, blocks: blocks, photos: [], documents: []),
      TL.RichMessage(blocks: blocks, photos: [.photoEmpty(.init(id: 1))], documents: []),
      TL.RichMessage(blocks: blocks, photos: [], documents: [.documentEmpty(.init(id: 1))])] {
      #expect(throws: ReceivedRichMessageError.incomplete) { try RichMessage.inputMessage(received: rich) }
    }
    let rich = TL.RichMessage(blocks: [.pageBlockParagraph(.init(text: .textDiff(.init(
      text: Text("new").richText, oldText: Text("old").richText))))], photos: [], documents: [])
    #expect(throws: RichMessageValidationError.unsupportedRichText("textDiff")) {
      try RichMessage.inputMessage(received: rich)
    }
  }
  @Test func uploadedAttachmentUsesCallerPlacementAndCaption() throws {
    let attachment = try UploadedDocument(.messageMediaDocument(.init(document: document)), caption: Text("Download"))
    let message = RichMessage { Paragraph("Before"); attachment; Paragraph("After") }
    let converted = try RichMessage.inputMessage(blocks: message.blocks, documents: [attachment.document])
    guard case .inputRichMessage(let rich) = converted,
       case .pageBlockDocument(let block) = rich.blocks[1] else { Issue.record("Missing attachment"); return }
    #expect(block.documentId == 33 && block.caption.text == Text("Download").richText)
    guard case .document(let full) = document else { Issue.record("expected a document"); return }
    #expect(rich.documents == [.inputDocument(.init(id: full.id, accessHash: full.accessHash, fileReference: full.fileReference))])
    #expect(try TL.InputRichMessageType(tlData: converted.tlSerialized()) == converted)
  }
  @Test func uploadedAttachmentRejectsMissingDocument() {
    for media: TL.MessageMediaType in [.messageMediaEmpty(.init()),
      .messageMediaDocument(.init(document: .documentEmpty(.init(id: 1))))] {
      #expect(throws: UploadedDocumentError.missingDocument) { try UploadedDocument(media, caption: Text("File")) }
    }
  }
  @Test func attachmentsUseSharedInputValidation() throws {
    let attachment = try UploadedDocument(.messageMediaDocument(.init(document: document)),
      caption: Inline(richText: .textHashtag(.init(text: Text("#example").richText))))
    let message = RichMessage { attachment }
    guard case .inputRichMessage(let rich) = try RichMessage.inputMessage(blocks: message.blocks, documents: [attachment.document]),
       case .pageBlockDocument(let block) = rich.blocks.first else { Issue.record("Missing attachment"); return }
    #expect(block.caption.text == Text("#example").richText)
    let invalid = try UploadedDocument(.messageMediaDocument(.init(document: document)),
      caption: Inline(richText: .textDiff(.init(text: Text("new").richText, oldText: Text("old").richText))))
    #expect(throws: RichMessageValidationError.unsupportedRichText("textDiff")) {
      try RichMessage.inputMessage(blocks: invalid.blocks, documents: [invalid.document])
    }
  }
  @Test func messageLinksUseNeutralPeerIDs() {
    let peers: [TL.PeerType] = [.peerChannel(.init(channelId: 2)), .peerChat(.init(chatId: 3)), .peerUser(.init(userId: 4))]
    let urls = ["https://t.me/c/2/7", "tg://openmessage?chat_id=3&message_id=7", "tg://openmessage?user_id=4&message_id=7"]
    for (peer, url) in zip(peers, urls) {
      #expect(MessageLink(peer: peer, messageID: 7).richText == Text("7").link(to: url).richText)
      #expect(MessageLink(peer: peer, messageID: 7, label: "View").richText == Text("View").link(to: url).richText)
    }
  }
}
