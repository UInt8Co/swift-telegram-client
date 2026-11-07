#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Storage-only JSON tree. Integer tokens never pass through Double.
public indirect enum ArchiveJSON: Codable, Equatable, Sendable {
  /// An object, emitted with sorted keys by `text()`.
  case object([String: ArchiveJSON])
  /// An array retaining element order.
  case array([ArchiveJSON])
  /// A JSON string.
  case string(String)
  /// A signed integer token, never converted through Double.
  case integer(Int64)
  /// An unsigned integer outside the signed range.
  case unsigned(UInt64)
  /// A floating-point value; use `TLArchive.prettyPrintedJSON` to preserve its spelling.
  case number(Double)
  /// A Boolean value.
  case bool(Bool)
  /// The null value.
  case null

  /// Decodes integers before floating-point values to preserve Int64 and UInt64 precision.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Int64.self) { self = .integer(v) }
    else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
    else if let v = try? c.decode(Double.self) { self = .number(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([ArchiveJSON].self) { self = .array(v) }
    else { self = .object(try c.decode([String: ArchiveJSON].self)) }
  }
  /// Encodes the stored JSON value without changing integer precision.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .integer(let v): try c.encode(v)
    case .unsigned(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  /// Parses JSON, throwing on malformed input.
  public init(_ json: String) throws { self = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
  /// Serializes compact JSON with sorted keys and unescaped slashes.
  public func text() throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
  /// The string value, or nil for another JSON kind.
  public var string: String? { if case .string(let v) = self { v } else { nil } }
  /// Looks up an object member, returning nil for non-objects or absent keys.
  public subscript(_ key: String) -> Self? { if case .object(let v) = self { v[key] } else { nil } }

  /// Removes reflected TL defaults, flags, and binary duplicates, preserving constructors.
  /// Apply only to reflected TL trees, not to an application envelope.
  public func compactTL() -> Self {
    switch self {
    case .array(let values): return .array(values.map { $0.compactTL() })
    case .object(let fields):
      if fields["_encoding"] == .string("base64") { return .object(["$rawBytes": .bool(true)]) }
      var result: [String: Self] = [:]
      for (key, value) in fields {
        if key == "_type" {
          if fields["_"] == nil { result["_"] = value }
          continue
        }
        if key == "flags" || key == "flags2" { continue }
        switch value {
        case .null, .bool(false), .integer(0), .unsigned(0), .number(0), .string(""): continue
        case .array(let v) where v.isEmpty: continue
        case .object(let v) where v.isEmpty: continue
        default: result[key] = value.compactTL()
        }
      }
      return .object(result)
    default: return self
    }
  }
}
