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

  /// Inflates a payload into its HTML, refusing anything the server could not
  /// have produced.
  public static func html(fromPayload payload: Data) throws(DecodingError) -> String {
    throw .corrupt
  }
}
