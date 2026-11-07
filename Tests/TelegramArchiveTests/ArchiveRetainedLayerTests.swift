#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramArchive
import TelegramSchema
import Testing

@Suite struct ArchiveRetainedLayerTests {
  private static func word(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }

  /// Rewrites the boxed `part` inside `whole` to carry an earlier constructor.
  private static func legacy(_ whole: Data, part: some TLEncodable, constructor: UInt32) throws -> Data {
    var bytes = [UInt8](whole)
    let needle = [UInt8](part.tlSerialized())
    let start = try #require((0...bytes.count - needle.count).first { bytes[$0..<$0 + needle.count].elementsEqual(needle) })
    bytes.replaceSubrange(start..<start + 4, with: word(constructor))
    return Data(bytes)
  }

  @Test func layer231ReplyHeaderDecodesWithoutRenumberingEqualData() throws {
    let header = TL.MessageReplyHeaderType.messageReplyHeader(.init(replyToMsgId: 5, quoteText: "quoted"))
    // The message ID is the same word as the legacy constructor and must survive.
    let message = TL.MessageType.message(TL.Message(id: Int32(bitPattern: 0x1b97_dd66), peerId: .peerChat(.init(chatId: 1)),
                            replyTo: header, date: 1, message: "text"))
    let old = try Self.legacy(message.tlSerialized(), part: header, constructor: 0x1b97_dd66)
    #expect(throws: TLError.self) { try TL.MessageType(tlData: old) }
    #expect(try TL.MessageType(retainedTL: old) == message)
  }

  @Test func everyNestedLegacyConstructorIsRenumbered() throws {
    let first = TL.ChatType.channel(.init(id: 1, title: "one", photo: .chatPhotoEmpty(.init()), date: 1))
    let second = TL.ChatType.channel(.init(id: 2, title: "two", photo: .chatPhotoEmpty(.init()), date: 2))
    let chats = [first, second]
    var old = try Self.legacy(chats.tlSerialized(), part: first, constructor: 0xd49f_34c6)
    old = try Self.legacy(old, part: second, constructor: 0xd49f_34c6)
    #expect(try [TL.ChatType](retainedTL: old) == chats)
  }

  @Test func unknownConstructorsStillFail() throws {
    let header = TL.MessageReplyHeaderType.messageReplyHeader(.init(replyToMsgId: 5))
    let unknown = try Self.legacy(header.tlSerialized(), part: header, constructor: 0xdead_beef)
    #expect(throws: TLError.self) { try TL.MessageReplyHeaderType(retainedTL: unknown) }
  }

  @Test func legacyConstructorsMapToCurrentLayer() {
    let current: Set<UInt32> = [TL.Channel.tlConstructorID, TL.ChannelFull.tlConstructorID, TL.InputReplyToMessage.tlConstructorID,
                  TL.MessageReplyHeader.tlConstructorID, TL.UserFull.tlConstructorID, TL.Wallet.NftItem.tlConstructorID]
    #expect(Set(TLArchive.legacyConstructors.values) == current)
    #expect(Set(TLArchive.legacyConstructors.keys).isDisjoint(with: current))
  }

  @Test func allShippedLayer231LayoutsDecode() throws {
    func check<T: TLEncodable & TLDecodable & Equatable>(_ value: T, old: UInt32) throws {
      let bytes = try Self.legacy(value.tlSerialized(), part: value, constructor: old)
      #expect(try TLArchive.decode(T.self, from: bytes) == value)
    }
    try check(TL.Channel(id: 1, title: "one", photo: .chatPhotoEmpty(.init()), date: 1), old: 0xd49f_34c6)
    try check(TL.ChannelFull(id: 1, about: "About", readInboxMaxId: 0, readOutboxMaxId: 0,
      unreadCount: 0, chatPhoto: .photoEmpty(.init(id: 1)), notifySettings: .init(), botInfo: [], pts: 1), old: 0xa04e_8d3a)
    try check(TL.InputReplyToMessage(replyToMsgId: 1, quoteText: "quoted"), old: 0x3bd4_b7c2)
    try check(TL.MessageReplyHeader(replyToMsgId: 1, quoteText: "quoted"), old: 0x1b97_dd66)
    try check(TL.UserFull(id: 1, settings: .init(), notifySettings: .init(), commonChatsCount: 0), old: 0x06cb_e645)
    try check(TL.Wallet.NftItem(address: "item", ownerAddress: "owner", index: "1"), old: 0x3441_fd1c)
  }

  @Test func fixedHistoricalReplyHeaderBytesDecode() throws {
    // Layer 231: flags=16 (reply_to_msg_id), reply_to_msg_id=5.
    let bytes = Data([0x66, 0xdd, 0x97, 0x1b, 0x10, 0, 0, 0, 5, 0, 0, 0])
    #expect(try TL.MessageReplyHeader(retainedTL: bytes) == TL.MessageReplyHeader(replyToMsgId: 5))
    #expect(throws: TLError.self) { try TL.MessageReplyHeader(tlData: bytes) }
  }
}
