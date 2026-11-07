#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramSchema

/// Lossless boxed TL bytes plus a compact, recursively reflected JSON view.
/// TL types are generated structs, not Codable. Reflection preserves nondefault
/// semantic fields and constructors; Int64 values remain JSON integer tokens.
public enum TLArchive {
  /// Archives original boxed bytes and a sorted compact JSON view at the current layer.
  /// Reflection preserves integer precision; only JSON serialization can throw.
  /// This synchronous operation does not check task cancellation.
  public static func payload(_ value: some TLEncodable) throws -> TLArchivePayload {
    let constructor = String(describing: type(of: value))
    let bytes = value.tlSerialized()
    // Compact the reflected tree directly: one reflection and one encode,
    // with no TL decode or JSON parse on the live write path.
    var tree = jsonValue(value).compactTL()
    if case .object(var fields) = tree {
      fields[TLArchiveStorage.marker] = .object(["version": .integer(1),
        "constructor": .string(constructor), "layer": .integer(Int64(TelegramSchemaLayer.current))])
      tree = .object(fields)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json = String(decoding: try encoder.encode(tree), as: UTF8.self)
    return TLArchivePayload(constructor: constructor, bytes: bytes, json: json)
  }

  /// Reflects all fields, including defaults, into sorted JSON with escaped slashes.
  /// This presentation is reconstructible only for supported TL layouts.
  public static func legacyJSON(_ value: some TLEncodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(jsonValue(value)), as: UTF8.self)
  }

  /// Retained constructors whose current-layer successor only added fields
  /// behind flag bits the earlier layer never defined. Their bytes are the
  /// successor's with those bits clear, so renumbering decodes them as-is.
  /// Layout changes (for example, changing a string field into an object) cannot
  /// be listed here. Update this table and its fixtures on every schema layer bump.
  public static let legacyConstructors: [UInt32: UInt32] = [
    0xd49f_34c6: 0x7ad1_5240, // channel, layer 231
    0xa04e_8d3a: 0xc4c4_dd40, // channelFull, layer 231
    0x3bd4_b7c2: 0x75c1_ad70, // inputReplyToMessage, layer 231
    0x1b97_dd66: 0xddb5_ab75, // messageReplyHeader, layer 231
    0x06cb_e645: 0xb90c_2afd, // userFull, layer 231
    0x3441_fd1c: 0x173d_faf3, // wallet.nftItem, layer 231
  ]

  /// Decodes retained boxed TL, which may predate the current layer. The
  /// reader stops just past a rejected constructor, so only words the decoder
  /// read as constructors are renumbered; equal values inside data are kept.
  /// Caller substitutions override built-in entries. Cycles and unknown layouts
  /// throw the underlying constructor error. Input bytes remain unchanged, and
  /// trailing bytes are permitted as by the underlying TL reader. Synchronous;
  /// no cancellation checks are performed.
  public static func decode<T: TLDecodable>(_ type: T.Type, from data: Data,
                      substitutions: [UInt32: UInt32] = [:]) throws -> T {
    let constructors = legacyConstructors.merging(substitutions) { _, custom in custom }
    var replaced: [Int: Set<UInt32>] = [:]
    var bytes = [UInt8](data)
    while true {
      var reader = TLReader(bytes)
      do {
        return try T(tlFrom: &reader)
      } catch TLError.unexpectedConstructor(let found, let expected) {
        let at = reader.offset - 4
        guard let current = constructors[found], at >= 0, at <= bytes.count - 4,
            replaced[at, default: []].insert(found).inserted,
            bytes[at..<at + 4].elementsEqual(withUnsafeBytes(of: found.littleEndian, Array.init)) else {
          throw TLError.unexpectedConstructor(found: found, expected: expected)
        }
        bytes.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: current.littleEndian, Array.init))
      }
    }
  }

  private enum JSONValue: Encodable {
    case string(String), bool(Bool), integer(Int64), unsigned(UInt64), double(Double), float(Float)
    case object([String: JSONValue]), array([JSONValue]), null

    /// Same L1 rules as ArchiveJSON.compactTL, before serialization. Keeping
    /// Float as Float preserves the original encoder's numeric precision.
    func compactTL() -> Self {
      switch self {
      case .array(let values): return .array(values.map { $0.compactTL() })
      case .object(let fields):
        if case .string("base64") = fields["_encoding"] { return .object(["$rawBytes": .bool(true)]) }
        var result: [String: Self] = [:]
        for (key, value) in fields {
          if key == "_type" {
            if fields["_"] == nil { result["_"] = value }
            continue
          }
          if key == "flags" || key == "flags2" { continue }
          switch value {
          case .null, .bool(false), .integer(0), .unsigned(0), .double(0), .float(0), .string(""): continue
          case .array(let v) where v.isEmpty: continue
          case .object(let v) where v.isEmpty: continue
          default: result[key] = value.compactTL()
          }
        }
        return .object(result)
      default: return self
      }
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .string(let value): try container.encode(value)
      case .bool(let value): try container.encode(value)
      case .integer(let value): try container.encode(value)
      case .unsigned(let value): try container.encode(value)
      case .double(let value): try container.encode(value)
      case .float(let value): try container.encode(value)
      case .object(let value): try container.encode(value)
      case .array(let value): try container.encode(value)
      case .null: try container.encodeNil()
      }
    }
  }

  private static func jsonValue(_ value: Any) -> JSONValue {
    switch value {
    case let value as String: return .string(value)
    case let value as Bool: return .bool(value)
    case let value as Int: return .integer(Int64(value))
    case let value as Int32: return .integer(Int64(value))
    case let value as Int64: return .integer(value)
    case let value as UInt32: return .unsigned(UInt64(value))
    case let value as UInt64: return .unsigned(value)
    case let value as Double: return .double(value)
    case let value as Float: return .float(value)
    case let value as Data: return .object(["_encoding": .string("base64"), "data": .string(value.base64EncodedString())])
    default: break
    }
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .optional:
      return mirror.children.first.map { jsonValue($0.value) } ?? .null
    case .collection, .set:
      return .array(mirror.children.map { jsonValue($0.value) })
    case .enum:
      if let child = mirror.children.first {
        let encoded = jsonValue(child.value)
        var result: [String: JSONValue]
        if case .object(let fields) = encoded { result = fields }
        else { result = ["value": encoded] }
        result["_"] = .string(child.label ?? String(describing: type(of: value)))
        return .object(result)
      }
      return .object(["_": .string(String(describing: value))])
    default:
      var result: [String: JSONValue] = ["_type": .string(String(describing: type(of: value)))]
      for (index, child) in mirror.children.enumerated() {
        result[child.label ?? String(index)] = jsonValue(child.value)
      }
      return .object(result)
    }
  }
}

extension TLDecodable {
  /// Decodes boxed TL using the retained-layer compatibility table.
  ///
  /// Caller substitutions override built-in entries. Only rejected constructor
  /// words are changed; the input data is untouched. Unknown layouts still throw.
  /// Like the underlying TL reader, this initializer permits trailing bytes.
  public init(retainedTL data: Data, substitutions: [UInt32: UInt32] = [:]) throws {
    self = try TLArchive.decode(Self.self, from: data, substitutions: substitutions)
  }
}
