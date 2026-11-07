#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramArchive
import TelegramSchema
import Testing

@Suite struct ArchiveGoldenTests {
  @Test func boxedBytesAndReflectedJSON() throws {
    let value = TL.PeerUser(userId: 9_007_199_254_740_993)
    let payload = try TLArchive.payload(value)
    #expect(payload.constructor == "PeerUser")
    #expect(payload.bytes == Data([0x22, 0x17, 0x51, 0x59, 1, 0, 0, 0, 0, 0, 0x20, 0]))
    #expect(payload.json == #"{"_":"PeerUser","_archive":{"constructor":"PeerUser","layer":232,"version":1},"userId":9007199254740993}"#)
    #expect(try TLArchive.legacyJSON(value) == #"{"_type":"PeerUser","userId":9007199254740993}"#)
  }

  @Test func codableEnvelopeAndSidecarFraming() throws {
    let payload = TLArchivePayload(constructor: "Future", bytes: Data([0, 127, 255]),
      json: #"{"_":"Future","_archive":{"constructor":"Future","layer":999,"version":1},"id":9223372036854775807}"#)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let inline = #"[{"bytes":"AH//","constructor":"Future","json":"{\"_\":\"Future\",\"_archive\":{\"constructor\":\"Future\",\"layer\":999,\"version\":1},\"id\":9223372036854775807}"}]"#
    let compact = #"[{"constructor":"Future","json":"{\"_\":\"Future\",\"_archive\":{\"constructor\":\"Future\",\"layer\":999,\"version\":1},\"id\":9223372036854775807}","rawSlot":0}]"#
    let raw = Data([0x54, 0x4c, 0x52, 0x31, 1, 0, 0, 0, 3, 0, 0, 0, 0, 127, 255])
    #expect(String(decoding: try encoder.encode([payload]), as: UTF8.self) == inline)
    for body in [try TLArchiveStorage.pack(inline), try TLArchiveStorage.encode([payload])] {
      #expect(body.json == compact)
      #expect(body.raw == raw)
      #expect(try TLArchiveStorage.unpack(body.json, raw: body.raw) == inline)
      #expect(try TLArchiveStorage.decode([TLArchivePayload].self, json: body.json, raw: body.raw) == [payload])
    }
    #expect(payload.fullJSON() == payload.json)
    for damaged in [Data(), Data(raw.dropLast()), raw + Data([0]), Data("TLR9".utf8) + raw.dropFirst(4)] {
      #expect(throws: (any Error).self) { try TLArchiveStorage.unpack(compact, raw: damaged) }
    }
    #expect(throws: (any Error).self) { try TLArchiveStorage.unpack(compact, raw: nil) }
    #expect(throws: (any Error).self) { try TLArchiveStorage.pack("{") }
  }

  @Test func malformedAndUnknownViewsAreReadVerbatim() throws {
    for json in ["not JSON", #"{"_":"Future","_archive":{"version":99,"layer":999,"constructor":"Future"},"value":1}"#] {
      let payload = TLArchivePayload(constructor: "Future", bytes: Data([0]), json: json)
      let decoded = try JSONDecoder().decode(TLArchivePayload.self, from: JSONEncoder().encode(payload))
      #expect(decoded == payload)
      #expect(decoded.fullJSON() == json)
    }
  }
}
