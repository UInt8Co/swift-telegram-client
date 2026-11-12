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

/// Checks the observer's coverage against `Schemas/api.json` itself, not against
/// the generated code: the closure of types that can hold a `User` or a `Chat` is
/// derived here independently, and for every position one can sit in, a reply
/// with a peer in exactly that position is written byte by byte and sent through
/// ``PeerObservingTransport``. A type, field or method the generated code misses
/// — including one a schema update added without regenerating — fails here.
@Suite struct ReceivedPeersSchemaTests {
  @Test("every method whose result can hold a peer is read, and nothing else")
  func everyPeerCarryingMethodIsObserved() async throws {
    let schema = try TLTestSchema.load()
    var expectedMethods: Set<UInt32> = []
    for method in schema.methods where !method.isWrapper {
      guard let named = method.result.namedType, schema.carriers.contains(named) else { continue }
      expectedMethods.insert(method.id)
      let reply = try schema.reply(to: method, through: [])
      try await expectObserved(reply, request: method.id, method: method.name)
    }
    #expect(Set(ReceivedPeerReplies.methods.keys) == expectedMethods)
    #expect(expectedMethods.count > 300)
  }

  @Test("every field of every type that can hold a peer is visited")
  func everyPeerPositionIsObserved() async throws {
    let schema = try TLTestSchema.load()
    var positions = 0
    var unreceivable: Set<String> = []
    for type in schema.carriers.sorted() where !TLTestSchema.peerTypes.contains(type) {
      guard let route = schema.routes[type] else {
        // Only ever sent (`InputMedia`, …): no reply or push can contain it.
        unreceivable.insert(type)
        continue
      }
      for constructor in schema.constructorsByType[type]! {
        for (index, field) in constructor.fields.enumerated() {
          guard let named = field.value?.namedType, schema.carriers.contains(named) else { continue }
          let path = route.path + [.init(constructor: constructor.name, field: index)]
            + (schema.toPeer[named] ?? [])
          let reply = try schema.reply(to: route.method, through: path)
          try await expectObserved(
            reply, request: route.method.id, method: route.method.name,
            "\(constructor.name).\(field.name)")
          positions += 1
        }
      }
    }
    #expect(positions > 200)
    // Request-only types the closure reaches; a received type must never be here.
    #expect(unreceivable.allSatisfy { $0.hasPrefix("Input") })
  }

  @Test("every wrapper method is stepped into, every optional field present")
  func everyWrapperIsSteppedInto() async throws {
    let schema = try TLTestSchema.load()
    let getUsers = try #require(schema.methods.first { $0.name == "users.getUsers" })
    let wrappers = schema.methods.filter(\.isWrapper)
    #expect(Set(ReceivedPeerReplies.wrappers.keys) == Set(wrappers.map(\.id)))
    for wrapper in wrappers {
      var request = TLWriter()
      request.writeUInt32(wrapper.id)
      var unused = TLTestSchema.Sentinels()
      for field in wrapper.fields {
        if field.value == .query { break }
        try schema.writeField(field, of: wrapper.fields, allFlags: true, into: &request, &unused)
      }
      request.writeUInt32(getUsers.id)
      let reply = try schema.reply(to: getUsers, through: [])
      try await expectObserved(
        reply, request: request.data, method: "users.getUsers", methodID: getUsers.id, wrapper.name)
    }
  }

  private func expectObserved(
    _ reply: (Data, TLTestSchema.Sentinels), request: UInt32, method: String,
    _ position: String = ""
  ) async throws {
    var writer = TLWriter()
    writer.writeUInt32(request)
    try await expectObserved(reply, request: writer.data, method: method, methodID: request, position)
  }

  private func expectObserved(
    _ reply: (Data, TLTestSchema.Sentinels), request: Data, method: String, methodID: UInt32,
    _ position: String
  ) async throws {
    let observed = Mutex<[ReceivedPeers]>([])
    let observation = ReceivedPeerObservation()
    await observation.attach { peers in observed.withLock { $0.append(peers) } }
    let transport = PeerObservingTransport(base: CannedTransport([reply.0]), observation: observation)
    #expect(try await transport.send(request) == reply.0)
    let seen = observed.withLock { $0 }
    let users = seen.flatMap(\.users).map { user -> Int64 in
      if case .userEmpty(let value) = user { value.id } else { -1 }
    }
    let chats = seen.flatMap(\.chats).map { chat -> Int64 in
      if case .chatEmpty(let value) = chat { value.id } else { -1 }
    }
    #expect(!reply.1.users.isEmpty || !reply.1.chats.isEmpty, "\(method) \(position)")
    #expect(users == reply.1.users, "\(method) \(position)")
    #expect(chats == reply.1.chats, "\(method) \(position)")
    for peers in seen {
      let call = try #require(peers.call)
      #expect(call.method == method, "\(method) \(position)")
      // The call names its request type, and carries the whole decoded result.
      #expect(
        (call.function as? any TLConstructed.Type)?.tlConstructorID == methodID,
        "\(method) \(position)")
      #expect(
        (call.result as? any TLEncodable)?.tlSerialized() == reply.0, "\(method) \(position)")
    }
  }
}

/// `Schemas/api.json`, read without the generator, and a writer of synthetic
/// values that puts a numbered `userEmpty`/`chatEmpty` wherever a peer goes.
private struct TLTestSchema {
  static let peerTypes: Set<String> = ["User", "Chat"]
  static let builtinTypes: Set<String> = ["Bool", "True", "Null", "Vector t", "Object"]

  indirect enum Value: Equatable {
    case primitive(String)
    case vector(Value, bare: Bool)
    case named(String, bare: Bool)
    case query

    var namedType: String? {
      switch self {
      case .vector(let element, _): element.namedType
      case .named(let name, _): name
      default: nil
      }
    }
  }

  struct Field {
    var name: String
    var isFlags: Bool
    var condition: (flags: String, bit: Int)?
    /// `nil` for a `true` flag, which occupies no bytes.
    var value: Value?
  }

  struct Combinator {
    var name: String
    var id: UInt32
    var fields: [Field]
    var type: String
    var result: Value
    var isWrapper: Bool { fields.contains { $0.value == .query } }
  }

  struct Step: Equatable {
    var constructor: String
    var field: Int
  }

  struct Route {
    var method: Combinator
    var path: [Step]
  }

  struct Sentinels {
    var next: Int64 = 1_000
    var users: [Int64] = []
    var chats: [Int64] = []
  }

  var constructorsByType: [String: [Combinator]] = [:]
  var constructors: [String: Combinator] = [:]
  var methods: [Combinator] = []
  /// Types that can hold a `User` or a `Chat`, including those two.
  var carriers: Set<String> = []
  /// The shortest path from a carrier to a peer inside it.
  var toPeer: [String: [Step]] = [:]
  /// How a reply reaches each received carrier: a method, and a path from its result.
  var routes: [String: Route] = [:]
  /// The cheapest constructor of each type when every vector is empty and every flag clear.
  var minimal: [String: Combinator] = [:]

  static func load() throws -> Self {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try JSONDecoder().decode(
      JSON.self, from: Data(contentsOf: root.appendingPathComponent("Schemas/api.json")))
    return try Self(json)
  }

  private struct JSON: Decodable {
    struct Param: Decodable { var name: String; var type: String }
    struct Entry: Decodable {
      var id: String
      var predicate: String?
      var method: String?
      var params: [Param]
      var type: String
    }
    var constructors: [Entry]
    var methods: [Entry]
  }

  private init(_ json: JSON) throws {
    func excluded(_ name: String) -> Bool { name.hasPrefix("mtcute.") }
    func combinator(_ entry: JSON.Entry, name: String) throws -> Combinator {
      Combinator(
        name: name, id: UInt32(bitPattern: try #require(Int32(entry.id))),
        fields: try entry.params.map(Self.field), type: entry.type,
        result: try #require(Self.value(entry.type)))
    }
    for entry in json.constructors {
      guard let name = entry.predicate, !excluded(name), !Self.builtinTypes.contains(entry.type)
      else { continue }
      let value = try combinator(entry, name: name)
      constructors[name] = value
      constructorsByType[entry.type, default: []].append(value)
    }
    for entry in json.methods {
      guard let name = entry.method, !excluded(name) else { continue }
      methods.append(try combinator(entry, name: name))
    }

    // The closure, by fixpoint.
    carriers = Self.peerTypes
    var changed = true
    while changed {
      changed = false
      for (type, cs) in constructorsByType where !carriers.contains(type) {
        if cs.contains(where: { $0.fields.contains { $0.value?.namedType.map(carriers.contains) == true } }) {
          carriers.insert(type)
          changed = true
        }
      }
    }

    // Shortest paths down to a peer.
    for type in Self.peerTypes { toPeer[type] = [] }
    changed = true
    while changed {
      changed = false
      for (type, cs) in constructorsByType where carriers.contains(type) && !Self.peerTypes.contains(type) {
        for c in cs {
          for (index, field) in c.fields.enumerated() {
            guard let named = field.value?.namedType, let rest = toPeer[named] else { continue }
            let path = [Step(constructor: c.name, field: index)] + rest
            if toPeer[type].map({ path.count < $0.count }) ?? true {
              toPeer[type] = path
              changed = true
            }
          }
        }
      }
    }

    // Breadth-first from every method result, through carriers only.
    var queue: [String] = []
    for method in methods where !method.isWrapper {
      guard let named = method.result.namedType, carriers.contains(named), routes[named] == nil
      else { continue }
      routes[named] = Route(method: method, path: [])
      queue.append(named)
    }
    while !queue.isEmpty {
      let type = queue.removeFirst()
      guard !Self.peerTypes.contains(type), let route = routes[type] else { continue }
      for c in constructorsByType[type] ?? [] {
        for (index, field) in c.fields.enumerated() {
          guard let named = field.value?.namedType, carriers.contains(named), routes[named] == nil
          else { continue }
          routes[named] = Route(
            method: route.method, path: route.path + [Step(constructor: c.name, field: index)])
          queue.append(named)
        }
      }
    }

    // Cheapest finite constructors: flags clear, vectors empty.
    var cost: [String: Int] = ["User": 1, "Chat": 1]
    changed = true
    while changed {
      changed = false
      for (type, cs) in constructorsByType where !Self.peerTypes.contains(type) {
        for c in cs {
          var total = 1
          for field in c.fields where field.condition == nil && !field.isFlags {
            guard case .named(let name, _)? = field.value else { continue }
            guard let part = cost[declaringType(name)] else { total = .max; break }
            total += part
          }
          if total != .max, cost[type].map({ total < $0 }) ?? true {
            cost[type] = total
            minimal[type] = c
            changed = true
          }
        }
      }
    }
  }

  private static func field(_ param: JSON.Param) throws -> Field {
    if param.type == "#" { return Field(name: param.name, isFlags: true, condition: nil, value: nil) }
    if let question = param.type.firstIndex(of: "?") {
      let condition = param.type[..<question].split(separator: ".")
      return Field(
        name: param.name, isFlags: false,
        condition: (String(condition[0]), try #require(Int(condition[1]))),
        value: value(String(param.type[param.type.index(after: question)...])))
    }
    return Field(name: param.name, isFlags: false, condition: nil, value: value(param.type))
  }

  private static func value(_ text: String) -> Value? {
    if text.hasPrefix("%") {
      guard case .named(let name, _)? = value(String(text.dropFirst())) else { return nil }
      return .named(name, bare: true)
    }
    switch text {
    case "true": return nil
    case "!X", "X": return .query
    case "int", "long", "double", "string", "bytes", "int128", "int256", "Bool":
      return .primitive(text)
    default:
      for prefix in ["Vector<", "vector<"] where text.hasPrefix(prefix) && text.hasSuffix(">") {
        guard let element = value(String(text.dropFirst(prefix.count).dropLast())) else { return nil }
        return .vector(element, bare: prefix == "vector<")
      }
      return .named(text, bare: false)
    }
  }

  /// The type a reference names: a boxed type, or the type declaring a bare constructor.
  private func declaringType(_ name: String) -> String {
    constructorsByType[name] != nil ? name : constructors[name]?.type ?? name
  }

  // MARK: Writing

  /// `method`'s reply, following `path` from its result down to a peer, or along
  /// the shortest such path when `path` is empty.
  func reply(to method: Combinator, through path: [Step]) throws -> (Data, Sentinels) {
    let named = try #require(method.result.namedType)
    let path = path.isEmpty ? try #require(toPeer[named]) : path
    var writer = TLWriter()
    var sentinels = Sentinels()
    try write(method.result, onPath: true, path[...], into: &writer, &sentinels)
    return (writer.data, sentinels)
  }

  /// Writes one field of a constructor; with `allFlags`, every optional field is present.
  func writeField(
    _ field: Field, of fields: [Field], allFlags: Bool, into writer: inout TLWriter,
    _ sentinels: inout Sentinels
  ) throws {
    if field.isFlags {
      writer.writeUInt32(allFlags ? .max : 0)
    } else if field.condition == nil || allFlags, let value = field.value {
      try write(value, onPath: false, [], into: &writer, &sentinels)
    }
  }

  private func write(
    _ value: Value, onPath: Bool, _ path: ArraySlice<Step>, into writer: inout TLWriter,
    _ sentinels: inout Sentinels
  ) throws {
    switch value {
    case .query:
      Issue.record("a query inside a received value")
    case .primitive(let name):
      switch name {
      case "int": writer.writeInt32(0)
      case "long": writer.writeInt64(0)
      case "double": writer.writeDouble(0)
      case "string": writer.writeString("")
      case "bytes": writer.writeBytes(Data())
      case "int128": writer.writeInt128(.zero)
      case "int256": writer.writeInt256(.zero)
      default: true.tlEncode(to: &writer)
      }
    case .vector(let element, let bare):
      if !bare { writer.writeUInt32(tlVectorConstructorID) }
      writer.writeInt32(onPath ? 1 : 0)
      if onPath { try write(element, onPath: true, path, into: &writer, &sentinels) }
    case .named(let name, let bare):
      let type = declaringType(name)
      if Self.peerTypes.contains(type) {
        let empty = try #require(constructors[type == "User" ? "userEmpty" : "chatEmpty"])
        sentinels.next += 1
        if !bare { writer.writeUInt32(empty.id) }
        writer.writeInt64(sentinels.next)
        if type == "User" { sentinels.users.append(sentinels.next) } else { sentinels.chats.append(sentinels.next) }
        return
      }
      let step = onPath ? path.first : nil
      let constructor = try #require(
        step.flatMap { constructors[$0.constructor] } ?? minimal[type], "no finite \(type)")
      #expect(constructor.type == type)
      if !bare { writer.writeUInt32(constructor.id) }
      var bits: [String: UInt32] = [:]
      if let step, let condition = constructor.fields[step.field].condition {
        bits[condition.flags, default: 0] |= 1 << UInt32(condition.bit)
      }
      for (index, field) in constructor.fields.enumerated() {
        if field.isFlags {
          writer.writeUInt32(bits[field.name] ?? 0)
          continue
        }
        if let condition = field.condition,
          (bits[condition.flags] ?? 0) & (1 << UInt32(condition.bit)) == 0
        {
          continue
        }
        guard let fieldValue = field.value else { continue }
        let follows = step?.field == index
        try write(
          fieldValue, onPath: follows, follows ? path.dropFirst() : [], into: &writer, &sentinels)
      }
    }
  }
}
