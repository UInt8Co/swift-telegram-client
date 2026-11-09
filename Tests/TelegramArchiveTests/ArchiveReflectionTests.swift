#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramArchive
import TelegramSchema
import Testing

@Suite struct ArchiveReflectionTests {
  @Test func reflectedJSONPreservesIntegerExtremesBinaryAndNulls() throws {
    struct Sample: TLEncodable {
      let signed = Int64.min
      let unsigned = UInt64.max
      let small = Int32.max
      let flag = true
      let float = Float(1.25)
      let double = Double(2.5)
      let missing: Int64? = nil
      let bytes = Data([0, 127, 255])
      func tlEncode(to writer: inout TLWriter) { writer.writeInt64(signed) }
    }
    struct Decoded: Decodable {
      struct Bytes: Decodable {
        let encoding: String
        let data: String
        enum CodingKeys: String, CodingKey { case encoding = "_encoding", data }
      }
      let signed: Int64
      let unsigned: UInt64
      let small: Int32
      let flag: Bool
      let float: Float
      let double: Double
      let missing: Int64?
      let bytes: Bytes
    }
    let sample = Sample()
    let payload = try TLArchive.payload(sample)
    #expect(payload.json == #"{"_":"Sample","_archive":{"constructor":"Sample","layer":233,"version":1},"bytes":{"$rawBytes":true},"double":2.5,"flag":true,"float":1.25,"signed":-9223372036854775808,"small":2147483647,"unsigned":18446744073709551615}"#)
    #expect(try TLArchive.legacyJSON(sample) == #"{"_type":"Sample","bytes":{"_encoding":"base64","data":"AH\/\/"},"double":2.5,"flag":true,"float":1.25,"missing":null,"signed":-9223372036854775808,"small":2147483647,"unsigned":18446744073709551615}"#)
    let value = try JSONDecoder().decode(Decoded.self, from: Data(TLArchive.legacyJSON(sample).utf8))
    #expect(value.signed == sample.signed && value.unsigned == sample.unsigned && value.small == sample.small)
    #expect(value.flag && value.float == sample.float && value.double == sample.double)
    #expect(value.missing == nil && !payload.json.contains("\"missing\":null"))
    #expect(value.bytes.encoding == "base64" && Data(base64Encoded: value.bytes.data) == sample.bytes)
    #expect(try ArchiveJSON(payload.json)["bytes"]?["$rawBytes"] == .bool(true))
    #expect(payload.json == (try TLArchiveStorage.compact(TLArchive.legacyJSON(sample),
      constructor: payload.constructor, producingLayer: TelegramSchemaLayer.current)))
    #expect(payload.bytes == sample.tlSerialized())
  }
}
