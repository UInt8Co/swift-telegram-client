#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramSchema

/// Plain L1 JSON is readable independently of any Telegram decoder or layer.
public enum TLArchiveStorage {
  /// Storage validation or top-level decoder lookup failed.
  public enum Failure: Error {
    /// Compact JSON did not round-trip without changing its semantic value.
    case invalidArchive
    /// No decoder is registered for the stored constructor name.
    case unsupportedSchema
    /// Sidecar framing or slot ownership is invalid.
    case invalidSidecar
  }
  /// Reserved compact-view metadata key; version 1 is the current format.
  public static let marker = "_archive"

  /// Reconstructs a legacy reflected view using the selected top-level decoder registry.
  /// Unsupported constructor names or undecodable layouts throw.
  public static func reflected(_ constructor: String, bytes: Data,
                registry: TLArchiveRegistry = .standard) throws -> String {
    try registry.reflected(constructor, bytes: bytes)
  }

  /// Removes reflected defaults and attaches version 1 metadata without decoding TL.
  /// Existing metadata or non-TL JSON is returned verbatim. Invalid JSON throws.
  public static func compact(_ json: String, constructor: String? = nil,
            producingLayer: Int32? = nil) throws -> String {
    let original = try ArchiveJSON(json)
    if original[marker] != nil { return json }
    guard original["_type"]?.string != nil || original["_"]?.string != nil else { return json }
    guard let name = constructor ?? original["_type"]?.string ?? original["_"]?.string,
        case .object(var fields) = original.compactTL() else { return json }
    var metadata: [String: ArchiveJSON] = ["version": .integer(1), "constructor": .string(name)]
    if let producingLayer { metadata["layer"] = .integer(Int64(producingLayer)) }
    fields[marker] = .object(metadata)
    let compact = ArchiveJSON.object(fields)
    let result = try compact.text()
    // Verify the serialized semantic view once, at conversion, never on reads.
    guard try ArchiveJSON(result) == compact else { throw Failure.invalidArchive }
    return result
  }

  /// Best-effort legacy presentation. Unknown layers, constructors, malformed data,
  /// or a semantic mismatch return the stored view verbatim. No data is discarded.
  public static func expandedJSON(_ json: String, bytes: Data,
                  registry: TLArchiveRegistry = .standard) -> String {
    guard let root = try? ArchiveJSON(json), let metadata = root[marker],
        metadata["version"] == .integer(1),
        let name = metadata["constructor"]?.string else { return json }
    if let layer = metadata["layer"], layer != .integer(Int64(TelegramSchemaLayer.current)) { return json }
    guard let full = try? reflected(name, bytes: bytes, registry: registry),
        let rebuilt = try? ArchiveJSON(full), case .object(var fields) = root else { return json }
    fields.removeValue(forKey: marker)
    guard rebuilt.compactTL() == .object(fields) else { return json }
    return full
  }

  /// Recognizes the canonical compact prefix without parsing or validating JSON.
  public static func isCompact(_ json: String) -> Bool {
    json.hasPrefix("{\"_\":") && json.contains("\"_archive\":{")
  }

  /// A JSON envelope and its optional framed raw TL sidecar.
  public struct Body: Sendable {
    /// Sorted JSON with raw slots, or the original text when packing made no changes.
    public var json: String
    /// `TLR1`, a little-endian UInt32 count, then UInt32 lengths and blob bytes.
    public var raw: Data?
    /// Creates a storage body without validating it; use `decode` or `unpack` to read it.
    public init(json: String, raw: Data?) { self.json = json; self.raw = raw }
  }

  /// Encodes a value once, placing nested archive bytes in a `TLR1` sidecar.
  /// Slots follow the encoder's traversal order; JSON keys are sorted. Use `pack`
  /// when historical JSON requires sorted-key slot order. Synchronous, with no
  /// cancellation checks; each call owns its mutable encoding context.
  public static func encode<T: Encodable>(_ value: T) throws -> Body {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let sidecar = SidecarWriter()
    encoder.userInfo[sidecarKey] = sidecar
    let json = String(decoding: try encoder.encode(value), as: UTF8.self)
    return .init(json: json, raw: try frame(sidecar.blobs))
  }

  // Like Sidecar, this mutable context belongs to one synchronous encode only.
  final class SidecarWriter: @unchecked Sendable {
    var blobs: [Data] = []
    func append(_ bytes: Data) -> Int {
      let index = blobs.count; blobs.append(bytes); return index
    }
  }

  /// Packs nested inline archives without decoding historical TL bytes.
  /// Visits object keys in sorted order and arrays in order; rejects existing slots.
  /// With no convertible archives, returns the input verbatim and no sidecar.
  /// This synchronous traversal does not check cancellation.
  public static func pack(_ json: String) throws -> Body {
    var blobs: [Data] = []
    func visit(_ value: ArchiveJSON) throws -> ArchiveJSON {
      switch value {
      case .array(let values): return .array(try values.map(visit))
      case .object(var fields):
        if fields["rawSlot"] != nil { throw Failure.invalidSidecar }
        if let constructor = fields["constructor"]?.string, let encoded = fields["bytes"]?.string,
          let legacy = fields["json"]?.string, let raw = Data(base64Encoded: encoded) {
          let layer: Int32?
          if case .integer(let value) = fields["producingLayer"] { layer = Int32(exactly: value) }
          else { layer = nil }
          let compactJSON = try isCompact(legacy) ? legacy
            : compact(legacy, constructor: constructor, producingLayer: layer)
          guard isCompact(compactJSON) else { return value }
          fields.removeValue(forKey: "bytes")
          fields["rawSlot"] = .integer(Int64(blobs.count)); blobs.append(raw)
          fields["json"] = .string(compactJSON)
          return .object(fields)
        }
        for key in fields.keys.sorted() { fields[key] = try visit(fields[key]!) }
        return .object(fields)
      default: return value
      }
    }
    let tree = try visit(ArchiveJSON(json))
    guard !blobs.isEmpty else { return .init(json: json, raw: nil) }
    return .init(json: try tree.text(), raw: try frame(blobs))
  }

  private static func frame(_ blobs: [Data]) throws -> Data? {
    guard !blobs.isEmpty else { return nil }
    var raw = Data("TLR1".utf8)
    func word(_ value: Int) throws {
      guard let n = UInt32(exactly: value) else { throw Failure.invalidSidecar }
      withUnsafeBytes(of: n.littleEndian) { raw.append(contentsOf: $0) }
    }
    try word(blobs.count)
    for blob in blobs { try word(blob.count); raw.append(blob) }
    return raw
  }

  /// Normal nested reads decode the envelope once. Payload JSON stays an
  /// opaque compact string; resolving a raw slot never parses that string.
  /// Rejects duplicate, missing, conflicting, or unused slots and malformed framing.
  /// Synchronous, with an isolated context per call and no cancellation checks.
  public static func decode<T: Decodable>(_ type: T.Type, json: String, raw: Data?) throws -> T {
    let decoder = JSONDecoder()
    let sidecar = try raw.map { Sidecar(try sidecarBlobs($0)) }
    decoder.userInfo[sidecarKey] = sidecar
    let result = try decoder.decode(type, from: Data(json.utf8))
    if let sidecar, sidecar.used.count != sidecar.blobs.count { throw Failure.invalidSidecar }
    return result
  }

  static let sidecarKey = CodingUserInfoKey(rawValue: "TLArchiveStorage.raw")!
  // JSONDecoder traverses an envelope synchronously. This context is local to
  // one decode, never shared across tasks; Sendable is required by userInfo.
  final class Sidecar: @unchecked Sendable {
    let blobs: [Data]
    var used = Set<Int>()
    init(_ blobs: [Data]) { self.blobs = blobs }
    func take(_ index: Int) throws -> Data {
      guard blobs.indices.contains(index), used.insert(index).inserted else { throw Failure.invalidSidecar }
      return blobs[index]
    }
  }

  private static func sidecarBlobs(_ raw: Data) throws -> [Data] {
    let bytes = [UInt8](raw)
    guard bytes.count >= 8, bytes.prefix(4).elementsEqual("TLR1".utf8) else { throw Failure.invalidSidecar }
    var offset = 4
    func word() throws -> Int {
      guard offset <= bytes.count - 4 else { throw Failure.invalidSidecar }
      let n = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
      offset += 4; return Int(n)
    }
    let count = try word()
    guard count <= (bytes.count - 8) / 4 else { throw Failure.invalidSidecar }
    var blobs: [Data] = []
    for _ in 0..<count {
      let length = try word()
      guard length <= bytes.count - offset else { throw Failure.invalidSidecar }
      blobs.append(Data(bytes[offset..<offset + length])); offset += length
    }
    guard offset == bytes.count else { throw Failure.invalidSidecar }
    return blobs
  }

  /// Restores inline base64 bytes without decoding TL or changing stored JSON strings.
  /// Validates framing, slot bounds, unique ownership, and complete blob consumption.
  /// With no sidecar and no slot references, returns the input verbatim. Otherwise
  /// emits sorted JSON. Synchronous; no cancellation checks are performed.
  public static func unpack(_ json: String, raw: Data?) throws -> String {
    guard let raw else {
      if json.contains("\"rawSlot\"") {
        func hasReference(_ value: ArchiveJSON) -> Bool {
          switch value {
          case .object(let fields): fields["rawSlot"] != nil || fields.values.contains(where: hasReference)
          case .array(let values): values.contains(where: hasReference)
          default: false
          }
        }
        if try hasReference(ArchiveJSON(json)) { throw Failure.invalidSidecar }
      }
      return json
    }
    let blobs = try sidecarBlobs(raw)
    var used = Set<Int>()
    func visit(_ value: ArchiveJSON) throws -> ArchiveJSON {
      switch value {
      case .array(let values): return .array(try values.map(visit))
      case .object(var fields):
        if let slot = fields["rawSlot"] {
          guard case .integer(let index) = slot, index >= 0, index < blobs.count,
              fields["bytes"] == nil, fields["constructor"]?.string != nil,
              let json = fields["json"]?.string,
              used.insert(Int(index)).inserted else { throw Failure.invalidSidecar }
          let blob = blobs[Int(index)]
          fields.removeValue(forKey: "rawSlot")
          fields["bytes"] = .string(blob.base64EncodedString())
          fields["json"] = .string(json)
          return .object(fields)
        }
        for key in fields.keys.sorted() { fields[key] = try visit(fields[key]!) }
        return .object(fields)
      default: return value
      }
    }
    let result = try visit(ArchiveJSON(json))
    guard used.count == blobs.count else { throw Failure.invalidSidecar }
    return try result.text()
  }
}

extension TLArchivePayload {
  /// Best-effort legacy presentation, with the stored JSON as a permanent fallback.
  public func fullJSON(registry: TLArchiveRegistry = .standard) -> String {
    TLArchiveStorage.expandedJSON(json, bytes: bytes, registry: registry)
  }

  /// Compact storage view, or the original text if compaction fails. Does not decode TL.
  public var storageJSON: String {
    // Generated archives start with the constructor tag and metadata. Avoid
    // parsing on repeated writes of the same in-memory compact payload.
    if TLArchiveStorage.isCompact(json) { return json }
    return (try? TLArchiveStorage.compact(json, constructor: constructor)) ?? json
  }
}
