#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramArchive
import TelegramSchema
import Testing

@Suite struct ArchiveStorageTests {
  func message() throws -> TLArchivePayload {
    try TLArchive.payload(TL.Message(id: 7, peerId: .peerUser(.init(userId: Int64.max)),
      date: 123, message: "A message"))
  }

  @Test func defaultPresenceAndLargeIntegersRemainLossless() throws {
    let value = TL.UserType.user(.init(id: Int64.max, accessHash: 0, firstName: "", usernames: []))
    let payload = try TLArchive.payload(value)
    let stored = payload.storageJSON
    #expect(!stored.contains("accessHash"))
    #expect(try ArchiveJSON(stored)["id"] == .integer(Int64.max))
    #expect(stored == payload.json)
  }

  @Test func reservedWordsInOrdinaryTextAreNotReferences() throws {
    let json = #"{"text":"rawSlot","note":"_archive"}"#
    let body = try TLArchiveStorage.pack(json)
    #expect(body.json == json && body.raw == nil)
    #expect(try TLArchiveStorage.unpack(json, raw: nil) == json)
  }

  @Test func malformedSidecarsSlotsAndRawAreRejected() throws {
    let payload = try message()
    let json = String(decoding: try JSONEncoder().encode([payload]), as: UTF8.self)
    let body = try TLArchiveStorage.pack(json)
    let raw = try #require(body.raw)
    for damaged in [Data(), Data(raw.dropLast()), raw + Data([0]), Data("TLR9".utf8) + raw.dropFirst(4)] {
      #expect(throws: (any Error).self) { try TLArchiveStorage.unpack(body.json, raw: damaged) }
    }
    for slot in ["-1", "1", "1.5", "\"0\""] {
      let damaged = body.json.replacing( "\"rawSlot\":0", with: "\"rawSlot\":\(slot)")
      #expect(throws: (any Error).self) { try TLArchiveStorage.unpack(damaged, raw: raw) }
    }
    let duplicated = "[" + body.json.dropFirst().dropLast() + "," + body.json.dropFirst().dropLast() + "]"
    #expect(throws: (any Error).self) { try TLArchiveStorage.unpack(duplicated, raw: raw) }
    var impossibleCount = raw
    impossibleCount.replaceSubrange(4..<8, with: [255, 255, 255, 255])
    #expect(throws: (any Error).self) { try TLArchiveStorage.unpack(body.json, raw: impossibleCount) }
    // Raw bytes and unknown metadata are readable without consulting a TL decoder.
    let future = body.json.replacing( "\"version\":1", with: "\"version\":2")
    #expect(try TLArchiveStorage.unpack(future, raw: raw).contains("version"))
    #expect(throws: (any Error).self) { try TLArchiveStorage.unpack(body.json, raw: nil) }
    var corrupt = raw; corrupt[corrupt.count - 1] ^= 1
    #expect(try TLArchiveStorage.unpack(body.json, raw: corrupt).contains("json"))

  }

  @Test func directEnvelopeDecoderValidatesSidecarsWithoutDecodingTL() throws {
    let payload = try message()
    let body = try TLArchiveStorage.pack(String(decoding: JSONEncoder().encode([payload]), as: UTF8.self))
    let raw = try #require(body.raw)
    for damaged in [Data(), Data(raw.dropLast()), raw + Data([0])] {
      #expect(throws: (any Error).self) { try TLArchiveStorage.decode([TLArchivePayload].self, json: body.json, raw: damaged) }
    }
    for slot in ["-1", "1", "1.5", "\"0\""] {
      let json = body.json.replacing( "\"rawSlot\":0", with: "\"rawSlot\":\(slot)")
      #expect(throws: (any Error).self) { try TLArchiveStorage.decode([TLArchivePayload].self, json: json, raw: raw) }
    }
    let duplicated = "[" + body.json.dropFirst().dropLast() + "," + body.json.dropFirst().dropLast() + "]"
    #expect(throws: (any Error).self) { try TLArchiveStorage.decode([TLArchivePayload].self, json: duplicated, raw: raw) }
    #expect(throws: (any Error).self) { try TLArchiveStorage.decode([TLArchivePayload].self, json: "[]", raw: raw) }
    #expect(throws: (any Error).self) { try TLArchiveStorage.decode([TLArchivePayload].self, json: body.json, raw: nil) }
    var undecodable = raw
    undecodable.replaceSubrange(12..<16, with: [0, 0, 0, 0])
    let restored = try TLArchiveStorage.decode([TLArchivePayload].self, json: body.json, raw: undecodable)
    #expect(restored[0].json == payload.json)
    #expect(restored[0].fullJSON() == payload.json)
  }

}
