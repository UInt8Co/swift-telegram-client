import MTProtoClientKit
import Synchronization
import TelegramClient
import TelegramSchema
import Testing

@Suite struct ParticipantFallbackTests {
  private let target = TL.ChannelParticipantType.channelParticipant(.init(userId: 7, date: 0))

  @Test func positiveEvidenceDoesNotRequireCountsOrCompleteLists() async throws {
    let target = target
    #expect(try await ChannelParticipantLookup.fallback(userID: 7, role: .member,
      count: { throw ParticipantLookupError.incomplete(.hiddenParticipants) },
      page: { _, _, _ in ParticipantLookupFixture.page([target], count: 9000) }))
    let lookup = ParticipantLookupFixture(pages: [ParticipantLookupFixture.page([target], count: 2)], expectedCount: 100)
    #expect(try await lookup.contains(role: .member))
  }

  @Test func partialLaterPagesCanStillProvePresence() async throws {
    let other = TL.ChannelParticipantType.channelParticipant(.init(userId: 1, date: 0))
    let lookup = ParticipantLookupFixture(pages: [
      ParticipantLookupFixture.page([other], count: 2), ParticipantLookupFixture.page([target], count: 2),
    ], expectedCount: 1000)
    #expect(try await lookup.contains(role: .member))
    #expect(await lookup.requests.map(\.offset) == [0, 1])
  }

  @Test func completenessFailuresExplainWhyAbsenceIsUnknown() async throws {
    let other = TL.ChannelParticipantType.channelParticipant(.init(userId: 1, date: 0))
    let mismatch = ParticipantLookupFixture(pages: [ParticipantLookupFixture.page([other])], expectedCount: 10)
    await #expect(throws: ParticipantLookupError.incomplete(.countMismatch(expected: 10, actual: 1, offset: 0))) {
      try await mismatch.contains(role: .member)
    }
    let exhausted = ParticipantLookupFixture(pages: [ParticipantLookupFixture.page([other], count: 10), ParticipantLookupFixture.page([], count: 10)])
    await #expect(throws: ParticipantLookupError.incomplete(.earlyEnd(expected: 10, seen: 1))) {
      try await exhausted.contains(role: .member)
    }
  }

  @Test func aCompleteListLargerThanTheFullInfoCountProvesAbsence() async throws {
    let members = (1...3).map { TL.ChannelParticipantType.channelParticipant(.init(userId: Int64($0), date: 0)) }
    let completed = Mutex<[Set<Int64>]>([])
    #expect(try await ChannelParticipantLookup.fallback(userID: 7, role: .member,
      count: { 2 }, page: { _, _, _ in ParticipantLookupFixture.page(members, count: 3) },
      completed: { members in completed.withLock { $0.append(members) } }) == false)
    #expect(completed.withLock { $0 } == [Set([1, 2, 3])])
    // A list that falls short of the full-info count may be a subset.
    await #expect(throws: ParticipantLookupError.incomplete(.countMismatch(expected: 4, actual: 3, offset: 0))) {
      try await ChannelParticipantLookup.fallback(userID: 7, role: .member,
        count: { 4 }, page: { _, _, _ in ParticipantLookupFixture.page(members, count: 3) })
    }
  }

  @Test func traversalIsBoundedWhenTelegramNeverCompletesTheList() async throws {
    let calls = Mutex(0)
    await #expect(throws: ParticipantLookupError.incomplete(.traversalLimit(seen: 1000))) {
      try await ChannelParticipantLookup.fallback(userID: 7, role: .member, count: { 100_000 }, page: { _, offset, _ in
        calls.withLock { $0 += 1 }
        return ParticipantLookupFixture.page((0..<200).map {
          .channelParticipant(.init(userId: 100 + Int64(offset) + Int64($0), date: 0))
        }, count: 100_000)
      })
    }
    #expect(calls.withLock { $0 } == 5)
  }

  @Test func incompleteFallbackIsSharedButIndividualAnswersRemainFresh() async throws {
    let cache = ParticipantLookupCache()
    let calls = Mutex(0)
    let failure = ParticipantLookupError.incomplete(.earlyEnd(expected: 10, seen: 1))
    for user in [7, 8, 9] {
      await #expect(throws: failure) {
        try await ChannelParticipantLookup.contains(userID: Int64(user), role: .member,
          participant: { throw TelegramClientError.userNotFound(Int64(user)) }, fallback: {
            try await cache.run(channelID: 1, role: .member) {
              calls.withLock { $0 += 1 }
              throw failure
            }
          })
      }
    }
    #expect(calls.withLock { $0 } == 1)
    let target = target
    #expect(try await ChannelParticipantLookup.contains(userID: 7, role: .member,
      participant: { target }, fallback: { throw failure }))
    #expect(try await !ChannelParticipantLookup.contains(userID: 7, role: .member,
      participant: { nil }, fallback: { throw failure }))
    #expect(try await cache.run(channelID: 2, role: .member) { true })
    #expect(try await cache.run(channelID: 1, role: .admin) { false } == false)
  }

  @Test func repeatedPartialListsBackOffAndEventuallyRetryWithoutExtendingOnCacheHits() async throws {
    let clock = Mutex(ContinuousClock.now)
    let cache = ParticipantLookupCache(duration: .seconds(10), maximumDuration: .seconds(20), now: { clock.withLock { $0 } })
    let calls = Mutex(0)
    let failure = ParticipantLookupError.incomplete(.hiddenParticipants)
    for advance in [0, 5, 5, 10, 9] {
      clock.withLock { $0 = $0.advanced(by: .seconds(advance)) }
      await #expect(throws: failure) {
        try await cache.run(channelID: 1, role: .member) { calls.withLock { $0 += 1 }; throw failure }
      }
    }
    #expect(calls.withLock { $0 } == 2)
    clock.withLock { $0 = $0.advanced(by: .seconds(1)) }
    #expect(try await cache.run(channelID: 1, role: .member) { true })
    // A previous positive answer must never be reused for a different user.
    #expect(try await cache.run(channelID: 1, role: .member) { false } == false)
  }

  @Test func completeListsExpireAndInvalidationRejectsInflightOldSnapshots() async throws {
    let clock = Mutex(ContinuousClock.now)
    let cache = ParticipantLookupCache(now: { clock.withLock { $0 } })
    let first = await cache.generation
    await cache.recordComplete([7], channelID: 1, role: .member, generation: first)
    #expect(await cache.membership(userID: 7, channelID: 1, role: .member) == true)
    #expect(await cache.membership(userID: 8, channelID: 1, role: .member) == false)
    #expect(await cache.membership(userID: 8, channelID: 1, role: .admin) == nil)
    await cache.invalidate(channelID: 1)
    await cache.recordComplete([7], channelID: 1, role: .member, generation: first)
    #expect(await cache.membership(userID: 7, channelID: 1, role: .member) == nil)
    await cache.recordComplete([7], channelID: 1, role: .member, generation: await cache.generation)
    clock.withLock { $0 = $0.advanced(by: .seconds(60)) }
    #expect(await cache.membership(userID: 7, channelID: 1, role: .member) == nil)
  }

  @Test func partialListsCannotInstallCompleteSnapshots() async throws {
    let completed = Mutex<[Set<Int64>]>([])
    let target = target
    #expect(try await ChannelParticipantLookup.fallback(userID: 7, role: .member,
      count: { 1000 }, page: { _, _, _ in ParticipantLookupFixture.page([target], count: 1000) },
      completed: { members in completed.withLock { $0.append(members) } }))
    #expect(completed.withLock { $0.isEmpty })
    await #expect(throws: ParticipantLookupError.self) {
      try await ChannelParticipantLookup.fallback(userID: 8, role: .member,
        count: { 1000 }, page: { _, _, _ in ParticipantLookupFixture.page([target], count: 1) },
        completed: { members in completed.withLock { $0.append(members) } })
    }
    #expect(completed.withLock { $0.isEmpty })
    #expect(try await ChannelParticipantLookup.fallback(userID: 8, role: .member,
      count: { 1 }, page: { _, _, _ in ParticipantLookupFixture.page([target], count: 1) },
      completed: { members in completed.withLock { $0.append(members) } }) == false)
    #expect(completed.withLock { $0 } == [Set([Int64(7)])])
  }

  @Test func rpcFailuresAndCancellationAreNotSharedAsIncompleteLists() async throws {
    let cache = ParticipantLookupCache()
    for error in [MTProtoRPCError(code: 420, message: "FLOOD_WAIT_60") as any Error, CancellationError()] {
      do {
        _ = try await cache.run(channelID: 1, role: .member) { throw error }
        Issue.record("Expected failure")
      } catch let actual { #expect(String(describing: actual) == String(describing: error)) }
      #expect(try await cache.run(channelID: 1, role: .member) { true })
    }
  }
}
