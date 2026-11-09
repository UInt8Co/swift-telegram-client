import NIOMTProtoEncryption

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The packed form of a widget's HTML in `messageMediaWidget.payload` and
/// `botInlineMessageWidget.payload`: one zlib stream (RFC 1950) of UTF-8 HTML,
/// made by the server from the HTML a bot sends.
public enum WidgetPayload {
  /// The server's limit on a widget's HTML, in bytes.
  public static let maximumHTMLByteCount = 32_768

  public enum DecodingError: Error, Equatable, Sendable {
    /// Not a zlib stream: a wrong or corrupt two-byte header (gzip and raw
    /// deflate are refused).
    case notZlib
    /// The stream is truncated, corrupt, fails its checksum or asks for a
    /// preset dictionary.
    case corrupt
    /// The HTML would exceed ``maximumHTMLByteCount``.
    case tooLarge
    case invalidUTF8
    case containsNUL
  }

  /// Inflates the first complete zlib stream into its HTML. Bytes after that
  /// stream are ignored, including any subsequent zlib streams.
  public static func html(fromPayload payload: Data) throws(DecodingError) -> String {
    guard payload.count >= 2 else { throw .notZlib }
    let header = Array(payload.prefix(2))
    guard header[0] & 0x0f == 8, header[0] >> 4 <= 7,
      (Int(header[0]) * 256 + Int(header[1])) % 31 == 0
    else { throw .notZlib }
    guard header[1] & 0x20 == 0 else { throw .corrupt }
    let bytes: Data
    do {
      bytes = try MTProtoGzip.inflate(payload, maximumOutputSize: maximumHTMLByteCount)
    } catch MTProtoGzip.Error.outputLimitExceeded {
      throw .tooLarge
    } catch {
      throw .corrupt
    }
    guard let html = String(bytes: bytes, encoding: .utf8) else { throw .invalidUTF8 }
    guard !bytes.contains(0) else { throw .containsNUL }
    return html
  }
}
