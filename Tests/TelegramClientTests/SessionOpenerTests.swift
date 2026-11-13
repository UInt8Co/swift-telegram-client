import TLCoding
import Testing

@testable import TelegramClient
@testable import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Which query carries `invokeWithLayer(initConnection(…))`, and what it looks
/// like on the wire.
///
/// Telegram refuses every request on a session that never announced a layer, and
/// answers one that announces it twice no differently — so the failure this
/// guards is silent in one direction and invisible in the other.
@Suite struct SessionOpenerTests {
  private static let app = TelegramApp(
    apiID: 12345, apiHash: "hash", deviceModel: "Test Device", systemVersion: "TestOS 1",
    appVersion: "9.9", systemLangCode: "en-GB", langPack: "tdesktop", langCode: "en")
  private static let layer: Int32 = 229
  private static let query = TL.Help.GetConfig()

  private static func opener() -> TelegramSessionOpener {
    TelegramSessionOpener(app: app, layer: layer)
  }

  @Test("only the first query of a connection opens the session")
  func firstQueryIsWrapped() {
    let opener = Self.opener()

    let first = opener.opening(Self.query)
    let second = opener.opening(Self.query)
    let third = opener.opening(TL.Updates.GetState())

    #expect(first != nil, "the first query announces the layer")
    #expect(first?.query.query == Self.query, "around the query itself")
    #expect(second == nil, "every later query goes out bare")
    #expect(third == nil)
  }

  @Test("the envelope carries the layer, the app and the query it wraps")
  func envelopeIsWellFormed() throws {
    let envelope = try #require(Self.opener().opening(Self.query))
    // Its result is the query's own, so the reply decodes as `TL.Config`.
    #expect(type(of: envelope).ReturnType.self == TL.Config.self)
    #expect(RPCRequestSummary.describe(envelope).name == "help.getConfig")

    var reader = TLReader(envelope.tlSerialized())
    #expect(try reader.readUInt32() == 0xda9b_0d0d, "invokeWithLayer")
    #expect(try reader.readInt32() == Self.layer)
    #expect(try reader.readUInt32() == 0xc1cd_5ea9, "initConnection")
    #expect(try reader.readUInt32() == 0, "no proxy and no params, so no flags")
    #expect(try reader.readInt32() == Self.app.apiID)
    #expect(try reader.readString() == Self.app.deviceModel)
    #expect(try reader.readString() == Self.app.systemVersion)
    #expect(try reader.readString() == Self.app.appVersion)
    #expect(try reader.readString() == Self.app.systemLangCode)
    #expect(try reader.readString() == Self.app.langPack)
    #expect(try reader.readString() == Self.app.langCode)
    // Whatever is left is the wrapped query, byte for byte.
    #expect(try reader.readRawBytes(reader.bytesRemaining) == Self.query.tlSerialized())
  }

  @Test("two connections each open their own session")
  func openersAreIndependent() {
    #expect(Self.opener().opening(Self.query) != nil)
    #expect(Self.opener().opening(Self.query) != nil)
  }
}
