import MTProtoClientKit
import MTProtoCrypto
import NIOCore
import NIOMTProtoEncryption
import NIOPosix
import Synchronization
import TLCoding
import TelegramSchema
import Testing

@testable import TelegramClient

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct SessionResumeTests {
  @Test(arguments: [ResumeReply.silence, .close])
  private func transientFailureKeepsSessionFile(reply: ResumeReply) async throws {
    let fixture = try await ResumeFixture.make(replies: [reply, reply, reply])
    defer { fixture.removeDirectory() }
    let expected: MTProtoClientError = reply == .silence ? .timeout : .connectionClosed
    await #expect(throws: expected) { try await fixture.connect() }
    #expect(try await fixture.reopenedSession() == fixture.cached)
    #expect(fixture.server.observed.state.withLock { $0.connections } == 3)
    #expect(fixture.server.observed.state.withLock { Set($0.requests.map(\.sessionID)).count } == 3)
    let logs = fixture.warnings.withLock { $0 }
    #expect(logs.count == 3)
    #expect(logs.allSatisfy { $0.contains("resume identify failed") })
    #expect(logs.last?.contains("attempt 3/3") == true)
    try await fixture.server.channel.close()
  }

  @Test(arguments: [
    ResumeReply.rpcError("AUTH_KEY_UNREGISTERED"),
    .rpcError("AUTH_KEY_INVALID"), .rpcError("SESSION_REVOKED"),
    .rpcError("SESSION_EXPIRED"), .rpcError("AUTH_KEY_DUPLICATED"),
  ])
  private func serverInvalidityDiscardsSessionFile(reply: ResumeReply) async throws {
    let fixture = try await ResumeFixture.make(replies: [reply])
    defer { fixture.removeDirectory() }
    await #expect(throws: TelegramClientError.noStoredSession) { try await fixture.connect() }
    #expect(try await fixture.reopenedSession() == nil)
    #expect(fixture.server.observed.state.withLock { $0.connections } == 1)
    try await fixture.server.channel.close()
  }

  // The current dependency version loses framed server errors in its NIO
  // bridge. Exercise the exact persistence path with the surfaced error here;
  // swift-nio-mtproto tests the framing-to-error handoff independently.
  @Test(arguments: [Int32(-404), -429, -444])
  func transportErrorInvalidatesOnlyUnknownKey(code: Int32) async throws {
    let fixture = try await ResumeFixture.make(replies: [])
    defer { fixture.removeDirectory() }
    let discarded = try await TelegramConnection.discardInvalidCachedSession(
      MTProtoClientError.protocolError(code), store: fixture.store,
      key: ResumeFixture.sessionKey, log: .silent)
    #expect(discarded == (code == -404))
    #expect(try await fixture.reopenedSession() == (discarded ? nil : fixture.cached))
    try await fixture.server.channel.close()
  }

  @Test(arguments: ["FLOOD_WAIT_60", "AUTH_KEY_PERM_EMPTY", "USER_MIGRATE_4", "USER_DEACTIVATED"])
  func unrelatedRPCFailureKeepsSessionWithoutRetry(message: String) async throws {
    let fixture = try await ResumeFixture.make(replies: [.rpcError(message)])
    defer { fixture.removeDirectory() }
    await #expect(throws: MTProtoRPCError(code: 401, message: message)) {
      try await fixture.connect()
    }
    #expect(try await fixture.reopenedSession() == fixture.cached)
    #expect(fixture.server.observed.state.withLock { $0.connections } == 1)
    try await fixture.server.channel.close()
  }

  @Test(arguments: [false, true])
  func saltCorrectionResumesWithoutLogin(afterTimeout: Bool) async throws {
    let fixture = try await ResumeFixture.make(
      replies: afterTimeout ? [.silence, .saltThenIdentify] : [.saltThenIdentify])
    defer { fixture.removeDirectory() }
    let connection = try await fixture.connect(authorization: .botToken("42:test"))
    #expect(connection.resumedSession)
    #expect(connection.accountID == fixture.cached.accountID)
    #expect(try await fixture.reopenedSession() == fixture.cached)
    let requests = fixture.server.observed.state.withLock { $0.requests }
    #expect(requests.count == (afterTimeout ? 3 : 2))
    #expect(requests.last?.salt == ResumeServer.correctedSalt)
    #expect(requests.last?.msgID != requests[requests.count - 2].msgID)
    let identify = TL.Users.GetUsers(id: [.inputUserSelf(TL.InputUserSelf())]).tlSerialized()
    #expect(requests.allSatisfy { $0.body.suffix(identify.count) == identify })
    await connection.disconnect()
    try await fixture.server.channel.close()
  }

  @Test func connectFailureKeepsSessionAndNamesPhase() async throws {
    let fixture = try await ResumeFixture.make(replies: [])
    defer { fixture.removeDirectory() }
    try await fixture.server.channel.close()
    await #expect(throws: (any Error).self) { try await fixture.connect() }
    #expect(try await fixture.reopenedSession() == fixture.cached)
    let logs = fixture.warnings.withLock { $0 }
    #expect(logs.count == 3)
    #expect(logs.allSatisfy { $0.contains("resume connect failed") })
  }

  @Test func mismatchedTokenPreservesOriginalAccountKey() async throws {
    let fixture = try await ResumeFixture.make(replies: [])
    defer { fixture.removeDirectory() }
    await #expect(throws: TelegramClientError.sessionBelongsToAnotherAccount) {
      try await fixture.connect(authorization: .botToken("99:test"))
    }
    #expect(try await fixture.reopenedSession() == fixture.cached)
    #expect(fixture.server.observed.state.withLock { $0.connections } == 0)
    try await fixture.server.channel.close()
  }

  @Test func exportedSessionAcceptsHomeDCRedirect() async throws {
    let fixture = try await ResumeFixture.make(replies: [.rpcError("USER_MIGRATE_4")])
    defer { fixture.removeDirectory() }
    let connection = try await fixture.connect(
      authorization: .exported {
        Issue.record("a resumed session must not spend another exported authorization")
        throw TelegramClientError.noStoredSession
      })
    #expect(connection.resumedSession)
    #expect(try await fixture.reopenedSession() == fixture.cached)
    await connection.disconnect()
    try await fixture.server.channel.close()
  }
}

private final class ResumeFixture: Sendable {
  let directory: URL
  let store: FileTelegramSessionStore
  let cached: CachedTelegramSession
  let server: ResumeServer
  let warnings = Mutex<[String]>([])
  static let sessionKey = TelegramConnection.sessionKey(scope: "resume-test", dcID: 2)

  private init(
    directory: URL, store: FileTelegramSessionStore, cached: CachedTelegramSession,
    server: ResumeServer
  ) {
    self.directory = directory
    self.store = store
    self.cached = cached
    self.server = server
  }

  static func make(replies: [ResumeReply]) async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try FileTelegramSessionStore(directory: directory)
    let cached = CachedTelegramSession(
      session: MTProtoStoredSession(authKey: Data(repeating: 0xA5, count: 256), serverSalt: 11),
      accountID: 42)
    try await store.save(cached.session, accountID: cached.accountID, for: sessionKey)
    let server = try await ResumeServer.start(authKey: cached.session.authKey, replies: replies)
    return Self(directory: directory, store: store, cached: cached, server: server)
  }

  func connect(authorization: TelegramAuthorization = .storedSessionOnly) async throws
    -> TelegramConnection
  {
    try await TelegramConnection.connect(
      endpoint: server.endpoint, rsaPublicKey: TelegramService.production.rsaPublicKey,
      app: TelegramApp(apiID: 12345, apiHash: "test"), layer: TelegramSchemaLayer.current,
      authorization: authorization, sessionStore: store, sessionScope: "resume-test",
      timeouts: .init(connect: .seconds(1), request: .milliseconds(150)),
      log: TelegramLog(minimum: .warning) { _, message in
        self.warnings.withLock { $0.append(message) }
      }
    )
  }

  func reopenedSession() async throws -> CachedTelegramSession? {
    try await FileTelegramSessionStore(directory: directory).session(for: Self.sessionKey)
  }

  func removeDirectory() { try? FileManager.default.removeItem(at: directory) }
}

private enum ResumeReply: Equatable, Sendable {
  case silence
  case close
  case rpcError(String)
  case saltThenIdentify
}

/// A localhost MTProto peer: no credentials, external network, or mocked client.
private struct ResumeServer: Sendable {
  static let correctedSalt: Int64 = 12345
  struct Observed {
    var connections = 0
    var requests: [MTProtoPlainMessage] = []
  }
  let channel: any Channel
  let endpoint: TelegramEndpoint
  let observed: ResumeObservations

  static func start(authKey: Data, replies: [ResumeReply]) async throws -> Self {
    let observed = ResumeObservations()
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        let reply = observed.state.withLock { state in
          let index = state.connections
          state.connections += 1
          return index < replies.count ? replies[index] : .silence
        }
        return channel.eventLoop.submit {
          try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ResumeDecoder(authKey: authKey, reply: reply, observed: observed)))
        }
      }.bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(channel.localAddress?.port)
    return Self(
      channel: channel, endpoint: TelegramEndpoint(dcID: 2, host: "127.0.0.1", port: port),
      observed: observed)
  }
}

private final class ResumeObservations: Sendable {
  let state = Mutex(ResumeServer.Observed())
}

private struct ResumeDecoder: ByteToMessageDecoder {
  typealias InboundOut = ByteBuffer
  let authKey: Data
  let reply: ResumeReply
  let observed: ResumeObservations
  var receivedHeader = false
  var sequence: Int64 = 0

  mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws
    -> DecodingState
  {
    if !receivedHeader {
      guard let header = buffer.readInteger(endianness: .little, as: UInt32.self) else {
        return .needMoreData
      }
      #expect(header == 0xeeee_eeee)
      receivedHeader = true
    }
    guard
      let length = buffer.getInteger(at: buffer.readerIndex, endianness: .little, as: Int32.self),
      length > 0, buffer.readableBytes >= 4 + Int(length)
    else { return .needMoreData }
    buffer.moveReaderIndex(forwardBy: 4)
    let received = buffer.readBytes(length: Int(length))
    let bytes = try #require(received)
    let request = try MTProtoEncryptedMessage.decode(
      Data(bytes), authKey: authKey, direction: .fromClient)
    // Graceful destroy_session and acknowledgements do not need a reply.
    guard request.seqNo % 2 == 1 else {
      #expect((try? TL.Ping(tlData: request.body)) == nil, "resume must not send an explicit ping")
      return .continue
    }
    observed.state.withLock { $0.requests.append(request) }
    var body = TLWriter()
    switch reply {
    case .silence:
      return .continue
    case .close:
      context.close(promise: nil)
      return .continue
    case .rpcError(let message):
      body.writeUInt32(TL.RpcResult.tlConstructorID)
      body.writeInt64(request.msgID)
      body.writeRawData(TL.RpcError(errorCode: 401, errorMessage: message).tlSerialized())
    case .saltThenIdentify:
      if request.salt != ResumeServer.correctedSalt {
        body.writeRawData(
          TL.BadServerSalt(
            badMsgId: request.msgID, badMsgSeqno: request.seqNo, errorCode: 48,
            newServerSalt: ResumeServer.correctedSalt
          ).tlSerialized())
      } else {
        body.writeUInt32(TL.RpcResult.tlConstructorID)
        body.writeInt64(request.msgID)
        body.writeRawData([TL.UserType.user(TL.User(id: 42))].tlSerialized())
      }
    }
    let msgID = (Int64(Date().timeIntervalSince1970) << 32) + sequence * 4 + 1
    sequence += 1
    let payload = try MTProtoEncryptedMessage.encode(
      body: body.data, salt: ResumeServer.correctedSalt, sessionID: request.sessionID,
      msgID: msgID, seqNo: 0, authKey: authKey, authKeyID: MTProtoMessageCrypto.authKeyID(authKey),
      direction: .fromServer)
    write(payload, context: context)
    return .continue
  }

  private func write(_ payload: Data, context: ChannelHandlerContext) {
    var buffer = context.channel.allocator.buffer(capacity: payload.count + 4)
    buffer.writeInteger(Int32(payload.count), endianness: .little)
    buffer.writeBytes(payload)
    context.writeAndFlush(NIOAny(buffer), promise: nil)
  }
}
