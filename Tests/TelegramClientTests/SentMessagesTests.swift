#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import TelegramSchema
import TelegramClient

@Suite struct SentMessagesTests {
  private let chat = PeerID(kind: .channel, id: 200)
  @Test func sentResultUsesMatchingRandomIDAndRejectsAmbiguousUpdates() throws {
    let unrelated = TL.UpdateType.updateMessageID(.init(id: 19, randomId: 1))
    let related = TL.UpdateType.updateMessageID(.init(id: 20, randomId: 2))
    let result = TL.UpdatesType.updates(.init(updates: [unrelated, related], users: [], chats: [], date: 1, seq: 1))
    #expect(try SentMessages.sentAddress(result, destination: chat, randomID: 2) == .init(peer: chat, id: 20))
    let short = TL.UpdatesType.updateShortSentMessage(.init(out: true, id: 22, pts: 1, ptsCount: 1, date: 1))
    #expect(try SentMessages.sentAddress(short, destination: chat, randomID: 2).id == 22)
    #expect(throws: SentMessageError.self) {
      try SentMessages.sentAddress(result, destination: chat, randomID: 999)
    }
  }
  @Test func freshnessHeuristicRequiresRecentUneditedMessage() {
    func result(id: Int32 = 20, date: Int32, edited: Int32? = nil, replied: Int32 = 1_000) -> TL.UpdatesType {
      let message = TL.Message(out: true, id: id, peerId: chat.tl, date: date, message: "", editDate: edited)
      return .updates(.init(updates: [.updateMessageID(.init(id: id, randomId: 2)),
        .updateNewChannelMessage(.init(message: .message(message), pts: 1, ptsCount: 1))],
        users: [], chats: [], date: replied, seq: 0))
    }
    let address = MessageAddress(peer: chat, id: 20)
    // A new message is dated from the attempt on (a little clock skew allowed).
    #expect(SentMessages.appearsFreshUnedited(result(date: 1_000), address: address, sentAt: 1_000, dateTolerance: 2))
    #expect(SentMessages.appearsFreshUnedited(result(date: 999), address: address, sentAt: 1_000, dateTolerance: 2))
    // A reused random ID returns the earlier message with its own date or edit.
    #expect(!SentMessages.appearsFreshUnedited(result(date: 990), address: address, sentAt: 1_000, dateTolerance: 2))
    #expect(!SentMessages.appearsFreshUnedited(result(date: 990, replied: 990), address: address, sentAt: 1_000, dateTolerance: 2))
    #expect(!SentMessages.appearsFreshUnedited(result(date: 1_000, edited: 1_000), address: address, sentAt: 1_000, dateTolerance: 2))
    // A fresh reply envelope exposes an old message even when the local clock is behind.
    #expect(!SentMessages.appearsFreshUnedited(result(date: 990, replied: 1_030), address: address, sentAt: 990, dateTolerance: 2))
    // Nothing to judge by: edit to be safe.
    let mappingOnly = TL.UpdatesType.updates(.init(updates: [.updateMessageID(.init(id: 20, randomId: 2))],
      users: [], chats: [], date: 1_000, seq: 0))
    #expect(!SentMessages.appearsFreshUnedited(mappingOnly, address: address, sentAt: 1_000, dateTolerance: 2))
    #expect(!SentMessages.appearsFreshUnedited(result(id: 21, date: 1_000), address: address, sentAt: 1_000, dateTolerance: 2))
    let short = TL.UpdatesType.updateShortSentMessage(.init(out: true, id: 20, pts: 1, ptsCount: 1, date: 1_000))
    #expect(SentMessages.appearsFreshUnedited(short, address: address, sentAt: 1_000, dateTolerance: 2))
    #expect(!SentMessages.appearsFreshUnedited(short, address: address, sentAt: 1_010, dateTolerance: 2))
  }

  private func updates(_ values: [TL.UpdateType]) -> TL.UpdatesType {
    .updates(.init(updates: values, users: [], chats: [], date: 100, seq: 1))
  }
  private func mapping(_ id: Int32, _ randomID: Int64) -> TL.UpdateType {
    .updateMessageID(.init(id: id, randomId: randomID))
  }
  private func message(_ id: Int32) -> TL.UpdateType {
    .updateNewChannelMessage(.init(message: .message(.init(out: true, id: id,
      peerId: chat.tl, date: 100, message: "")), pts: 1, ptsCount: 1))
  }
  @Test func forwardPartialAndCompleteMappings() throws {
    let partial = try SentMessages.forwardedAddresses(updates([mapping(50, 20)]), ids: [1, 2],
      destination: chat, randomIDs: [10, 20])
    #expect(partial == [2: .init(peer: chat, id: 50)])
    let complete = try SentMessages.forwardedAddresses(updates([mapping(50, 20), mapping(40, 10), message(50)]),
      ids: [1, 2], destination: chat, randomIDs: [10, 20])
    #expect(complete == [1: .init(peer: chat, id: 40), 2: .init(peer: chat, id: 50)])
    let repeated = try SentMessages.forwardedAddresses(updates([mapping(40, 10), mapping(40, 10)]),
      ids: [1], destination: chat, randomIDs: [10])
    #expect(repeated[1]?.id == 40)
  }
  @Test func forwardFallbackSortsOnlyCompleteUnmappedResults() throws {
    let result = try SentMessages.forwardedAddresses(updates([message(50), message(40)]), ids: [2, 1],
      destination: chat, randomIDs: [10, 20])
    #expect(result == [2: .init(peer: chat, id: 40), 1: .init(peer: chat, id: 50)])
    #expect(throws: SentMessageError.missingMapping) {
      try SentMessages.forwardedAddresses(updates([message(40)]), ids: [1, 2], destination: chat, randomIDs: [10, 20])
    }
    #expect(try SentMessages.forwardedAddresses(updates([]), ids: [1], destination: chat, randomIDs: [10]).isEmpty)
  }
  @Test func forwardRejectsAmbiguousAndInvalidBatches() {
    for values in [[mapping(40, 10), message(50)], [mapping(40, 10), mapping(41, 10)],
      [mapping(40, 10), mapping(40, 20)], [message(40), message(40)]] {
      #expect(throws: SentMessageError.missingMapping) {
        try SentMessages.forwardedAddresses(updates(values), ids: [1, 2], destination: chat, randomIDs: [10, 20])
      }
    }
    for (ids, randomIDs): ([Int32], [Int64]) in [([1], []), ([1, 1], [10, 20]), ([1, 2], [10, 10])] {
      #expect(throws: SentMessageError.invalidBatch) {
        try SentMessages.forwardedAddresses(updates([]), ids: ids, destination: chat, randomIDs: randomIDs)
      }
    }
  }
  @Test func singleFallbackAndConflictingMappings() throws {
    #expect(try SentMessages.sentAddress(updates([message(40)]), destination: chat, randomID: 1).id == 40)
    for values in [[message(40), message(50)], [mapping(40, 10), mapping(50, 10)]] {
      #expect(throws: SentMessageError.missingMapping) {
        try SentMessages.sentAddress(updates(values), destination: chat, randomID: 10)
      }
    }
  }
  @Test func fallbacksExcludeMessagesAssignedToOtherRequests() throws {
    let foreign = updates([mapping(40, 99), message(40)])
    #expect(throws: SentMessageError.missingMapping) {
      try SentMessages.sentAddress(foreign, destination: chat, randomID: 10)
    }
    #expect(try SentMessages.forwardedAddresses(foreign, ids: [1], destination: chat, randomIDs: [10]).isEmpty)
    let mixed = updates([mapping(40, 99), message(40), message(50)])
    #expect(try SentMessages.sentAddress(mixed, destination: chat, randomID: 10).id == 50)
    #expect(try SentMessages.forwardedAddresses(mixed, ids: [1], destination: chat, randomIDs: [10])[1]?.id == 50)
    let conflict = updates([mapping(40, 10), mapping(40, 99), message(40)])
    #expect(throws: SentMessageError.missingMapping) {
      try SentMessages.sentAddress(conflict, destination: chat, randomID: 10)
    }
    #expect(throws: SentMessageError.missingMapping) {
      try SentMessages.forwardedAddresses(conflict, ids: [1], destination: chat, randomIDs: [10])
    }
  }

  @Test func shortForwardAndExtremeDates() throws {
    let short = TL.UpdatesType.updateShortSentMessage(.init(out: true, id: 40, pts: 1, ptsCount: 1, date: .min))
    #expect(try SentMessages.forwardedAddresses(short, ids: [7], destination: chat, randomIDs: [1])[7]?.id == 40)
    #expect(throws: SentMessageError.missingMapping) {
      try SentMessages.forwardedAddresses(short, ids: [7, 8], destination: chat, randomIDs: [1, 2])
    }
    #expect(SentMessages.appearsFreshUnedited(short, address: .init(peer: chat, id: 40), sentAt: .min, dateTolerance: 2))
    #expect(!SentMessages.appearsFreshUnedited(short, address: .init(peer: chat, id: 40), sentAt: .min, dateTolerance: -1))
  }
}
