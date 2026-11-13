import MTProtoClientKit
import Synchronization
import TLCoding
import TelegramSchema

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

  /// The envelope to send `query` in if it is this connection's first query;
  /// `nil` for every later one, which goes out bare.
  ///
  /// The envelope's result is the query's own, so the reply decodes as the type
  /// the query declares either way.
  func opening<Query: TLFunction>(
    _ query: Query
  ) -> TL.InvokeWithLayer<TL.InitConnection<Query>>? {
    // `exchanged` is true only for the call that won the swap, which is the
    // first query of this connection and so the one that opens the session.
    let (isFirstQuery, _) = opened.compareExchange(
      expected: false, desired: true, ordering: .relaxed)
    return isFirstQuery ? envelope(around: query) : nil
  }

  func envelope<Query: TLFunction>(
    around query: Query
  ) -> TL.InvokeWithLayer<TL.InitConnection<Query>> {
    TL.InvokeWithLayer(
      layer: layer,
      query: TL.InitConnection(
        apiId: app.apiID, deviceModel: app.deviceModel, systemVersion: app.systemVersion,
        appVersion: app.appVersion, systemLangCode: app.systemLangCode,
        langPack: app.langPack, langCode: app.langCode,
        query: query))
  }
}

/// Invokes queries over an MTProto session: the bottom of a `TLClient`'s
/// transport chain, and the one place a query is serialized and its reply
/// decoded.
///
/// The connection's first query is sent inside the session's
/// `invokeWithLayer(initConnection(…))` envelope; every later one goes out bare.
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

  public func invoke<Function: TLFunction>(_ function: Function) async throws -> Function.ReturnType {
    if let envelope = opener.opening(function) {
      return try await client.invoke(envelope)
    }
    return try await client.invoke(function)
  }
}
