#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import MTProtoClientKit
import Synchronization
import TelegramSchema
import Testing
@testable import TelegramClient

@Suite struct FloodGateTests {
  private struct GateTransport: TLClientTransport {
    let base: any TLClientTransport
    let floodGate: FloodGate
    static func describe(_ data: Data) -> (name: String, peer: String?) {
      let id = data.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
      let names: [UInt32: String] = [0x0d91a548: "users.getUsers",
        0xb60f5918: "users.getFullUser", 0xfef48f62: "messages.sendMessage"]
      return (names[id] ?? "unknown", nil)
    }
    func send(_ data: Data) async throws -> Data {
      let method = Self.describe(data).name
      if let error = floodGate.rejection(for: method) { throw error }
      do { return try await base.send(data) }
      catch {
        if case .floodWait(let seconds) = MTProtoDirective(error) {
          floodGate.record(method: method, wait: .seconds(seconds))
        }
        throw error
      }
    }
  }
  private final class Clock: Sendable {
    let value = Mutex(Duration.zero)
    func now() -> Duration { value.withLock { $0 } }
    func advance(_ duration: Duration) { value.withLock { $0 += duration } }
  }

  private final class FakeTransport: TLClientTransport {
    struct State {
      var errors: [String: [MTProtoRPCError]] = [:]
      var calls: [String] = []
    }
    let state = Mutex(State())
    func fail(_ method: String, _ message: String = "FLOOD_WAIT_30", code: Int32 = 420) {
      state.withLock { $0.errors[method, default: []].append(.init(code: code, message: message)) }
    }
    func send(_ requestBody: Data) async throws -> Data {
      let method = GateTransport.describe(requestBody).name
      let error = state.withLock { state -> MTProtoRPCError? in
        state.calls.append(method)
        guard state.errors[method]?.isEmpty == false else { return nil }
        return state.errors[method]?.removeFirst()
      }
      if let error { throw error }
      return Data()
    }
    var calls: [String] { state.withLock { $0.calls } }
  }

  private func users(_ id: Int64 = 7) -> Data {
    TL.Users.GetUsers(id: [.inputUser(.init(userId: id, accessHash: 999))]).tlSerialized()
  }
  private func sendMessage(_ chat: Int64) -> Data {
    TL.Messages.SendMessage(peer: .inputPeerChannel(.init(channelId: chat, accessHash: 999)),
                message: "PRIVATE BODY", randomId: 123).tlSerialized()
  }
  private func failure(_ transport: any TLClientTransport, _ request: Data) async throws -> MTProtoRPCError {
    do {
      _ = try await transport.send(request)
      Issue.record("Expected a flood rejection")
      throw TestFailure.missingError
    } catch let error as MTProtoRPCError { return error }
  }
  private enum TestFailure: Error { case missingError }

  @Test func floodBlocksSameMethodAcrossPeersAndWrappersButNotOtherMethods() async throws {
    let clock = Clock()
    let gate = FloodGate(now: clock.now, randomUnit: { 0 })
    let base = FakeTransport()
    base.fail("users.getUsers")
    let transport = GateTransport(base: base, floodGate: gate)
    let helper = GateTransport(base: base, floodGate: gate)
    #expect(try await failure(transport, users()).message == "FLOOD_WAIT_30")
    #expect(try await failure(helper, users(8)).message == "FLOOD_WAIT_30")
    _ = try await helper.send(TL.Users.GetFullUser(id: .inputUserSelf(.init())).tlSerialized())
    #expect(base.calls == ["users.getUsers", "users.getFullUser"])
    clock.advance(.milliseconds(29_100))
    let error = try await failure(helper, users())
    #expect(error.message == "FLOOD_WAIT_1")
    #expect(MTProtoDirective(error)?.wait == .seconds(2))
    clock.advance(.milliseconds(900))
    _ = try await helper.send(users())
    #expect(base.calls.count == 3)
    #expect(gate.deadlineCount == 0)
  }

  @Test func chatWritesDoNotHoldOtherChatsOrReads() async throws {
    let base = FakeTransport()
    let gate = FloodGate(randomUnit: { 0 })
    let transport = GateTransport(base: base, floodGate: gate)
    base.fail("messages.sendMessage")
    _ = try await failure(transport, sendMessage(1))
    _ = try await transport.send(sendMessage(2))
    _ = try await transport.send(users())
    #expect(base.calls.count == 3)
    #expect(gate.deadlineCount == 0)
    for name in ["messages.sendMessage", "messages.sendMedia", "messages.forwardMessages",
          "messages.editMessage", "messages.deleteMessages", "channels.deleteMessages",
          "channels.editBanned", "messages.deleteChatUser", "messages.uploadMedia",
          "messages.createForumTopic", "messages.setTyping", "ephemeral.sendMessage"] {
      #expect(!gate.gates(name))
    }
  }

  @Test func deadlinesNeverMoveEarlierAndExpiredUnusedMethodsArePruned() {
    let clock = Clock()
    let gate = FloodGate(now: clock.now, randomUnit: { 0 })
    gate.record(method: "users.getUsers", wait: .seconds(30))
    clock.advance(.seconds(5))
    gate.record(method: "users.getUsers", wait: .seconds(2))
    #expect(gate.rejection(for: "users.getUsers")?.message == "FLOOD_WAIT_25")
    gate.record(method: "users.getUsers", wait: .seconds(40))
    #expect(gate.rejection(for: "users.getUsers")?.message == "FLOOD_WAIT_40")
    gate.record(method: "channels.getChannels", wait: .seconds(50))
    clock.advance(.seconds(60))
    #expect(gate.rejection(for: "help.getConfig") == nil)
    #expect(gate.rejection(for: "help.getConfig") == nil)
    #expect(gate.deadlineCount == 0)
  }

  private actor InFlightTransport: TLClientTransport {
    var first: CheckedContinuation<Data, any Error>?
    var started: CheckedContinuation<Void, Never>?
    var calls = 0
    func waitForFirst() async {
      if first != nil { return }
      await withCheckedContinuation { started = $0 }
    }
    func send(_ requestBody: Data) async throws -> Data {
      calls += 1
      if calls == 1 {
        return try await withCheckedThrowingContinuation {
          first = $0
          started?.resume()
          started = nil
        }
      }
      throw MTProtoRPCError(code: 420, message: "FLOOD_WAIT_30")
    }
    func finishFirst() {
      first?.resume(throwing: MTProtoRPCError(code: 420, message: "FLOOD_WAIT_2"))
      first = nil
    }
  }

  @Test func lateShorterServerFloodCannotShortenAnotherInFlightRequestsDeadline() async throws {
    let clock = Clock()
    let gate = FloodGate(now: clock.now, randomUnit: { 0 })
    let base = InFlightTransport()
    let transport = GateTransport(base: base, floodGate: gate)
    let firstRequest = users()
    let first = Task { try await failure(transport, firstRequest) }
    await base.waitForFirst()
    #expect(try await failure(transport, users(8)).message == "FLOOD_WAIT_30")
    clock.advance(.seconds(5))
    await base.finishFirst()
    #expect(try await first.value.message == "FLOOD_WAIT_2")
    #expect(try await failure(transport, users(9)).message == "FLOOD_WAIT_25")
    #expect(await base.calls == 2)
  }

  @Test func jitterIsBoundedAndProtectsDeadlineWithoutExtendingItOnRejection() async throws {
    #expect(FloodJitter.wait(for: .seconds(30), randomUnit: { 0 }) == .seconds(30))
    #expect(FloodJitter.wait(for: .seconds(30), randomUnit: { 1 }) == .seconds(35))
    #expect(FloodJitter.wait(for: .seconds(300), randomUnit: { 1 }) == .seconds(310))
    let clock = Clock()
    let gate = FloodGate(now: clock.now, randomUnit: { 1 })
    let base = FakeTransport()
    base.fail("users.getUsers")
    let transport = GateTransport(base: base, floodGate: gate)
    _ = try await failure(transport, users())
    clock.advance(.seconds(30))
    #expect(try await failure(transport, users()).message == "FLOOD_WAIT_8")
    clock.advance(.seconds(5))
    _ = try await transport.send(users())
    #expect(base.calls.count == 2)
  }

  @Test func exclusionsAndAccountsAreExplicit() {
    let first = FloodGate(excludedMethods: [], randomUnit: { 0 })
    let second = FloodGate(excludedMethods: [], randomUnit: { 0 })
    first.record(method: "messages.sendMessage", wait: .seconds(10))
    #expect(first.rejection(for: "messages.sendMessage") != nil)
    #expect(second.rejection(for: "messages.sendMessage") == nil)
    #expect(FloodJitter.wait(for: .seconds(-1), randomUnit: { -1 }) == .zero)
    #expect(FloodJitter.wait(for: .seconds(30), randomUnit: { 2 }) == .seconds(35))
  }
}
