import TelegramBot
import TelegramSchema
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct PrecheckoutQueriesTests {
  private func query(_ id: Int64) -> TL.UpdateBotPrecheckoutQuery {
    .init(queryId: id, userId: 7, payload: Data([1]), currency: "XTR", totalAmount: 5)
  }

  @Test func extractsQueriesFromEveryPushContainer() {
    let queries = [query(1), query(2)]
    let updates = [
      TL.UpdateType.updateBotPrecheckoutQuery(queries[0]),
      .updateDeleteMessages(.init(messages: [5], pts: 1, ptsCount: 1)),
      .updateBotPrecheckoutQuery(queries[1]),
    ]
    #expect(
      PrecheckoutQueries.from(
        .updates(.init(updates: updates, users: [], chats: [], date: 1, seq: 1))) == queries)
    #expect(
      PrecheckoutQueries.from(
        .updatesCombined(
          .init(updates: updates, users: [], chats: [], date: 1, seqStart: 1, seq: 2))) == queries)
    #expect(
      PrecheckoutQueries.from(.updateShort(.init(update: updates[0], date: 1))) == [queries[0]])
    #expect(PrecheckoutQueries.from(.updatesTooLong(.init())).isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func slowOrFailedQueriesDoNotBlockOthersAndCancellationStopsHandlers() async throws {
    let intake = AsyncStream<TL.UpdateBotPrecheckoutQuery>.makeStream()
    let progress = AsyncStream<Int64>.makeStream()
    let worker = Task {
      await PrecheckoutQueries.run(
        intake.stream,
        handle: { query in
          if query.queryId == 1 {
            progress.continuation.yield(1)
            do { try await Task.sleep(for: .seconds(300)) } catch {
              progress.continuation.yield(-1)
              throw error
            }
          } else if query.queryId == 2 {
            throw CancellationError()
          } else {
            progress.continuation.yield(query.queryId)
          }
        }, onError: { query, _ in progress.continuation.yield(-query.queryId) })
    }
    defer {
      worker.cancel()
      intake.continuation.finish()
      progress.continuation.finish()
    }
    var iterator = progress.stream.makeAsyncIterator()
    intake.continuation.yield(query(1))
    #expect(await iterator.next() == 1)
    intake.continuation.yield(query(2))
    #expect(await iterator.next() == -2)
    intake.continuation.yield(query(3))
    #expect(await iterator.next() == 3)
    worker.cancel()
    #expect(await iterator.next() == -1)
    await worker.value
  }
}
