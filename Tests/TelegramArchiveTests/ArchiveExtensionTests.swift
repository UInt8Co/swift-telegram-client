#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramArchive
import TelegramSchema
import Testing

@Suite struct ArchiveExtensionTests {
  @Test func registryExtendsSupportedTopLevelTypesLocally() throws {
    let value = TL.PeerUser(userId: 42)
    let payload = try TLArchive.payload(value)
    #expect(payload.fullJSON() == payload.json)
    var registry = TLArchiveRegistry.standard
    registry.register(TL.PeerUser.self)
    #expect(payload.fullJSON(registry: registry) == (try TLArchive.legacyJSON(value)))
    #expect(payload.fullJSON() == payload.json)
    #expect(throws: TLArchiveStorage.Failure.unsupportedSchema) {
      try TLArchiveRegistry().reflected("PeerUser", bytes: payload.bytes)
    }
    var mismatched = payload
    mismatched.json = payload.json.replacing( "42", with: "43")
    #expect(mismatched.fullJSON(registry: registry) == mismatched.json)
    var future = payload
    future.json = payload.json.replacing( "\"layer\":233", with: "\"layer\":999")
    #expect(future.fullJSON(registry: registry) == future.json)
  }

  @Test func customSubstitutionsPreserveOriginalBytesAndRejectCycles() throws {
    let value = TL.PeerUser(userId: 42)
    var bytes = value.tlSerialized()
    bytes.replaceSubrange(0..<4, with: [0xef, 0xbe, 0xad, 0xde])
    let original = bytes
    let table: [UInt32: UInt32] = [0xdead_beef: TL.PeerUser.tlConstructorID]
    #expect(try TL.PeerUser(retainedTL: bytes, substitutions: table) == value)
    #expect(bytes == original)
    #expect(throws: TLError.self) { try TL.PeerUser(retainedTL: bytes) }
    for cycle: [UInt32: UInt32] in [
      [0xdead_beef: 0xdead_beef], [0xdead_beef: 0xdead_beee, 0xdead_beee: 0xdead_beef]
    ] {
      #expect(throws: TLError.self) { try TL.PeerUser(retainedTL: bytes, substitutions: cycle) }
    }
    #expect(try TL.PeerUser(retainedTL: value.tlSerialized() + Data([0])) == value)
    #expect(throws: (any Error).self) { try TL.PeerUser(retainedTL: Data()) }
  }

  @Test func nestedEnvelopesAndEmptyBlobsRoundTrip() throws {
    struct Envelope: Codable, Equatable {
      var title: String
      var children: [TLArchivePayload]
      var optional: TLArchivePayload?
    }
    let empty = TLArchivePayload(constructor: "Future", bytes: Data(),
      json: #"{"_type":"Future","id":18446744073709551615}"#)
    let value = Envelope(title: "rawSlot _archive", children: [empty,
      try TLArchive.payload(TL.Message(id: 1, peerId: .peerChat(.init(chatId: 2)), date: 3, message: "text"))])
    let body = try TLArchiveStorage.encode(value)
    let decoded = try TLArchiveStorage.decode(Envelope.self, json: body.json, raw: body.raw)
    #expect(decoded.title == value.title)
    #expect(decoded.children.map(\.bytes) == value.children.map(\.bytes))
    #expect(decoded.children[0].json == empty.storageJSON)
    let inline = try TLArchiveStorage.unpack(body.json, raw: body.raw)
    let packed = try TLArchiveStorage.pack(inline)
    #expect(packed.json == body.json && packed.raw == body.raw)
    #expect(try JSONDecoder().decode(Envelope.self, from: Data(inline.utf8)) == decoded)
    #expect(try TLArchiveStorage.encode([TLArchivePayload]()).raw == nil)
    let conflicting = body.json.replacing( "\"rawSlot\":0", with: "\"rawSlot\":0,\"bytes\":\"\"")
    #expect(throws: (any Error).self) {
      try TLArchiveStorage.decode(Envelope.self, json: conflicting, raw: body.raw)
    }
    #expect(throws: (any Error).self) { try TLArchiveStorage.unpack(conflicting, raw: body.raw) }
    #expect(throws: (any Error).self) { try TLArchiveStorage.pack(body.json) }
  }
}
