import TelegramSchema

/// A send receipt cannot be correlated safely with its request.
public enum SentMessageError: Error, Equatable, Sendable {
  /// The result is absent, incomplete, conflicting, or ambiguous.
  case missingMapping
  /// Source and random-ID arrays differ in length or contain duplicate IDs.
  case invalidBatch
}

/// Pure receipt decoding; these helpers neither send requests nor retry them.
public enum SentMessages {
  /// Resolves a random ID, a short sent result, or exactly one outgoing message
  /// at the destination. Conflicting mappings and ambiguous fallbacks throw.
  public static func sentAddress(_ result: TL.UpdatesType, destination: PeerID, randomID: Int64) throws -> MessageAddress {
    let updates: [TL.UpdateType]
    switch result {
    case .updateShortSentMessage(let value): return .init(peer: destination, id: value.id)
    case .updates(let value): updates = value.updates
    case .updatesCombined(let value): updates = value.updates
    case .updateShort(let value): updates = [value.update]
    default: throw SentMessageError.missingMapping
    }
    let mapped = Set(updates.compactMap { update -> Int32? in
      guard case .updateMessageID(let mapping) = update, mapping.randomId == randomID else { return nil }
      return mapping.id
    })
    guard mapped.count <= 1 else { throw SentMessageError.missingMapping }
    if let id = mapped.first { return .init(peer: destination, id: id) }
    let messages = updates.compactMap { update -> TL.Message? in
      let message: TL.MessageType
      switch update {
      case .updateNewMessage(let value): message = value.message
      case .updateNewChannelMessage(let value): message = value.message
      default: return nil
      }
      guard case .message(let value) = message, value.out, PeerID(value.peerId) == destination else { return nil }
      return value
    }
    guard messages.count == 1, let message = messages.first else { throw SentMessageError.missingMapping }
    return .init(peer: destination, id: message.id)
  }

  /// A heuristic, not proof of a new server-side execution. A matching message
  /// must be unedited and no older than the later local/envelope date minus
  /// `dateTolerance` seconds. Short results use the local date only. Negative
  /// tolerance or insufficient information returns false; no clock is read.
  public static func appearsFreshUnedited(_ result: TL.UpdatesType, address: MessageAddress, sentAt: Int32, dateTolerance: Int32) -> Bool {
    guard dateTolerance >= 0 else { return false }
    let updates: [TL.UpdateType]
    let replied: Int32
    switch result {
    case .updateShortSentMessage(let value):
      return value.id == address.id && Int64(value.date) >= Int64(sentAt) - Int64(dateTolerance)
    case .updates(let value): updates = value.updates; replied = value.date
    case .updatesCombined(let value): updates = value.updates; replied = value.date
    case .updateShort(let value): updates = [value.update]; replied = value.date
    default: return false
    }
    for update in updates {
      let message: TL.MessageType
      switch update {
      case .updateNewMessage(let value): message = value.message
      case .updateNewChannelMessage(let value): message = value.message
      default: continue
      }
      guard case .message(let value) = message, value.id == address.id,
        PeerID(value.peerId) == address.peer else { continue }
      // A reply that is built anew carries the server's current date.
      return value.editDate == nil && Int64(value.date) >= Int64(max(sentAt, replied)) - Int64(dateTolerance)
    }
    return false
  }

  /// Correlates source IDs with destination addresses. Explicit mappings may be
  /// partial. Without mappings, all outgoing destination messages must be present;
  /// ascending destination IDs are paired with request order. Mixed mapped and
  /// unmapped results, duplicate destination IDs, and conflicting mappings throw.
  /// Duplicate identical mapping updates are harmless. No ordering is promised
  /// by the returned dictionary. Input source and random IDs must each be unique.
  public static func forwardedAddresses(_ result: TL.UpdatesType, ids: [Int32], destination: PeerID,
    randomIDs: [Int64]) throws -> [Int32: MessageAddress] {
    guard ids.count == randomIDs.count, Set(ids).count == ids.count,
      Set(randomIDs).count == randomIDs.count else { throw SentMessageError.invalidBatch }
    let updates: [TL.UpdateType]
    switch result {
    case .updateShortSentMessage(let value):
      guard ids.count == 1 else { throw SentMessageError.missingMapping }
      return [ids[0]: .init(peer: destination, id: value.id)]
    case .updates(let value): updates = value.updates
    case .updatesCombined(let value): updates = value.updates
    case .updateShort(let value): updates = [value.update]
    default: throw SentMessageError.missingMapping
    }
    let sources = Dictionary(uniqueKeysWithValues: zip(randomIDs, ids))
    var receipts: [Int32: MessageAddress] = [:]
    for case .updateMessageID(let mapping) in updates {
      if let source = sources[mapping.randomId] {
        let address = MessageAddress(peer: destination, id: mapping.id)
        guard receipts[source] == nil || receipts[source] == address else { throw SentMessageError.missingMapping }
        receipts[source] = address
      }
    }
    let mapped = Set(receipts.values.map(\.id))
    guard mapped.count == receipts.count else { throw SentMessageError.missingMapping }
    let unmapped = updates.compactMap { update -> Int32? in
      let message: TL.MessageType
      switch update {
      case .updateNewMessage(let value): message = value.message
      case .updateNewChannelMessage(let value): message = value.message
      default: return nil
      }
      guard case .message(let value) = message, value.out, PeerID(value.peerId) == destination,
        !mapped.contains(value.id) else { return nil }
      return value.id
    }.sorted()
    if unmapped.isEmpty { return receipts }
    guard receipts.isEmpty, unmapped.count == ids.count, Set(unmapped).count == unmapped.count else { throw SentMessageError.missingMapping }
    return Dictionary(uniqueKeysWithValues: zip(ids, unmapped.map { MessageAddress(peer: destination, id: $0) }))
  }

}
