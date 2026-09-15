import MTProtoClientKit
import Synchronization
import TLCoding
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The application a connection presents itself as: the API credentials
/// Telegram issues per application, and the client description every session
/// opens with.
///
/// The credentials are not interchangeable with a user's or a bot's: `apiID`
/// and `apiHash` name the *application*, and Telegram rate-limits, and can ban,
/// per application. Obtain a pair at <https://my.telegram.org/apps>.
public struct TelegramApp: Sendable {
  public var apiID: Int32
  public var apiHash: String
  public var deviceModel: String
  public var systemVersion: String
  public var appVersion: String
  public var systemLangCode: String
  public var langPack: String
  public var langCode: String

  public init(
    apiID: Int32, apiHash: String, deviceModel: String = "Desktop",
    systemVersion: String = "Swift", appVersion: String = "1.0",
    systemLangCode: String = "en", langPack: String = "", langCode: String = "en"
  ) {
    self.apiID = apiID
    self.apiHash = apiHash
    self.deviceModel = deviceModel
    self.systemVersion = systemVersion
    self.appVersion = appVersion
    self.systemLangCode = systemLangCode
    self.langPack = langPack
    self.langCode = langCode
  }
}

/// A query whose body the caller already serialized.
///
/// `TLClientTransport` hands over bytes rather than a value, so the
/// `initConnection`/`invokeWithLayer` envelope is built around this instead of
/// re-deriving those two constructor numbers by hand. It is never decoded — the
/// transport returns the reply body to the generated client, which decodes it as
/// the type the original request declared.
struct TLSerializedQuery: TLFunction {
  typealias ReturnType = TLOpaqueReply
  var body: Data

  func tlEncode(to writer: inout TLWriter) { writer.writeRawData(body) }
}

/// The undecoded reply body of a ``TLSerializedQuery``.
struct TLOpaqueReply: TLDecodable, Sendable {
  var body: Data

  init(tlFrom reader: inout TLReader) throws {
    body = try reader.readRawBytes(reader.bytesRemaining)
  }
}

/// Opens an MTProto session with `invokeWithLayer(initConnection(…))` the way
/// Telegram requires, and leaves every later query alone.
///
/// The envelope goes out once per connection, on whatever the first query turns
/// out to be: it describes the client to the server for the life of the session,
/// so repeating it on every call only pays for the same strings again. Sending
/// it on *no* query is the failure that matters — the server answers
/// `CONNECTION_LAYER_INVALID` and nothing works — so which query carries it is
/// decided here, where it can be checked without a socket.
final class TelegramSessionOpener: Sendable {
  let app: TelegramApp
  let layer: Int32
  private let opened = Atomic<Bool>(false)

  init(app: TelegramApp, layer: Int32) {
    self.app = app
    self.layer = layer
  }

  /// The bytes to put on the wire for `query`, wrapped if this is the first one.
  func body(for query: Data) -> Data {
    // `exchanged` is true only for the call that won the swap, which is the
    // first query of this connection and so the one that opens the session.
    let (isFirstQuery, _) = opened.compareExchange(
      expected: false, desired: true, ordering: .relaxed)
    return isFirstQuery ? envelope(around: query) : query
  }

  func envelope(around query: Data) -> Data {
    TL.InvokeWithLayer(
      layer: layer,
      query: TL.InitConnection(
        apiId: app.apiID, deviceModel: app.deviceModel, systemVersion: app.systemVersion,
        appVersion: app.appVersion, systemLangCode: app.systemLangCode,
        langPack: app.langPack, langCode: app.langCode,
        query: TLSerializedQuery(body: query))
    ).tlSerialized()
  }
}

/// Delivers one serialized query over an MTProto session.
public final class TelegramTransport: TLClientTransport {
  public let client: MTProtoClient
  public let app: TelegramApp
  /// The API layer this transport announces, which is also the layer its
  /// replies and the server's pushes arrive in.
  public let layer: Int32
  private let opener: TelegramSessionOpener

  public init(client: MTProtoClient, app: TelegramApp, layer: Int32) {
    self.client = client
    self.app = app
    self.layer = layer
    self.opener = TelegramSessionOpener(app: app, layer: layer)
  }

  public func send(_ requestBody: Data) async throws -> Data {
    try await client.invokeRaw(opener.body(for: requestBody))
  }
}
