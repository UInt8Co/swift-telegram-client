#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Raw boxed TL bytes (including constructor ID), with a queryable legacy or compact JSON projection.
public struct TLArchivePayload: Codable, Sendable, Equatable {
  /// Reflected top-level type name, retained verbatim.
  public var constructor: String
  /// Original boxed TL bytes; never rewritten during decoding or presentation.
  public var bytes: Data
  /// Stored JSON view, retained verbatim even if malformed or from an unknown layer.
  public var json: String
  /// Creates an archive without validating its bytes or JSON.
  public init(constructor: String, bytes: Data, json: String) {
    self.constructor = constructor; self.bytes = bytes
    self.json = json
  }
  private enum CodingKeys: String, CodingKey { case constructor, bytes, json, rawSlot }
  /// Reads inline base64 bytes or a unique slot supplied by `TLArchiveStorage.decode`.
  /// Missing, duplicate, or conflicting slot references throw. JSON remains opaque.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    constructor = try c.decode(String.self, forKey: .constructor)
    if c.contains(.bytes) {
      guard !c.contains(.rawSlot) else { throw TLArchiveStorage.Failure.invalidSidecar }
      bytes = try c.decode(Data.self, forKey: .bytes)
    } else {
      guard let sidecar = decoder.userInfo[TLArchiveStorage.sidecarKey] as? TLArchiveStorage.Sidecar else {
        throw TLArchiveStorage.Failure.invalidSidecar
      }
      bytes = try sidecar.take(c.decode(Int.self, forKey: .rawSlot))
    }
    json = try c.decode(String.self, forKey: .json)
  }
  /// Writes inline bytes normally; `TLArchiveStorage.encode` writes a raw sidecar slot.
  /// Only sidecar encoding compacts a legacy JSON view.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(constructor, forKey: .constructor)
    if let sidecar = encoder.userInfo[TLArchiveStorage.sidecarKey] as? TLArchiveStorage.SidecarWriter {
      try c.encode(sidecar.append(bytes), forKey: .rawSlot)
      try c.encode(storageJSON, forKey: .json)
    } else {
      try c.encode(bytes, forKey: .bytes)
      try c.encode(json, forKey: .json)
    }
  }
}
