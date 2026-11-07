#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import TelegramBot

@Suite struct BotCommandSynchronizationTests {
  private let target = "first"
  private func makeSynchronization() -> BotCommandSynchronization<String> {
    .init(refreshInterval: 3600, progressDelay: 60, failureDelays: [300, 600, 1200, 2400, 3600])
  }
  private func ready() -> BotCommandSynchronization<String> {
    var sync = makeSynchronization()
    sync.request(groups: [target], signature: "v1")
    #expect(sync.begin() == [target])
    sync.finish()
    #expect(sync.begin() == nil)
    return sync
  }
  @Test func aBatchOfMembershipChangesNeedsOnlyOneSweep() {
    var sync = ready()
    for _ in 0..<10 { sync.refresh() }
    #expect(sync.begin() == [target])
    #expect(sync.begin() == nil)
    sync.finish()
    #expect(sync.begin() == nil)
  }

  @Test func changesDuringASweepAreNotLostOrAllowedToOverlapIt() {
    var sync = ready()
    sync.refresh()
    #expect(sync.begin() == [target])
    sync.refresh()
    #expect(sync.begin() == nil)
    sync.finish()
    #expect(sync.begin() == [target], "prerequisite must be read again after an in-flight sweep")
    sync.finish()
    #expect(sync.begin() == nil)
  }

  @Test func concurrentMaintenanceUsesTheLatestRegistry() {
    var sync = ready()
    sync.refresh()
    #expect(sync.begin() == [target])
    let another = "second"
    sync.request(groups: [target, another], signature: "v1")
    #expect(sync.begin() == nil)
    sync.finish()
    #expect(sync.begin() == [target, another])
  }

  @Test func updatesBeforeStartupCannotClearListsWithoutARegistry() {
    var sync = makeSynchronization()
    sync.refresh()
    #expect(sync.begin() == nil)
    sync.request(groups: [target], signature: "v1")
    #expect(sync.begin() == [target])
  }

  @Test func unchangedMinuteChecksDoNotStartSweepsAndSafetyRefreshIsHourly() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var sync = makeSynchronization()
    sync.request(groups: [target], signature: "v1", now: now)
    #expect(sync.begin() == [target])
    sync.finish(now: now)
    let revision = sync.revision
    for minute in 1..<60 {
      sync.request(groups: [target, target], signature: "v1", now: now.addingTimeInterval(Double(minute * 60)))
      #expect(sync.begin() == nil, "no publication, external work")
      #expect(sync.revision == revision)
    }
    sync.request(groups: [target], signature: "v1", now: now.addingTimeInterval(3600))
    #expect(sync.begin() == [target])
    #expect(sync.revision == revision + 1)
  }

  @Test func catalogAndAccessChangesRequestWorkWithoutWaitingForSafetyRefresh() {
    var sync = ready()
    sync.request(groups: [target], signature: "edited catalog")
    #expect(sync.begin() == [target])
    sync.finish()
    sync.invalidate()
    #expect(sync.begin() == [target])
  }

  @Test func registryChangesInvalidateOnlyAddedAndRemovedKeys() {
    var sync = ready()
    #expect(sync.request(groups: [target, target], signature: "v1").isEmpty)
    let another = "second"
    #expect(sync.request(groups: [target, another], signature: "v1") == [another])
    #expect(sync.begin() == [target, another])
    sync.finish()
    #expect(sync.request(groups: [another], signature: "v1") == [target])
    #expect(sync.begin() == [another])
    sync.finish()
    #expect(sync.request(groups: [another, target], signature: "v1") == [target])
    #expect(sync.begin() == [another, target])
  }

  @Test func productiveBatchesContinueButFailuresBackOffAndEventsBypassTheDelay() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var sync = makeSynchronization()
    sync.request(groups: [target], signature: "v1", now: now)
    #expect(sync.begin() != nil)
    sync.finish(remaining: true, madeProgress: true, now: now)
    sync.request(groups: [target], signature: "v1", now: now.addingTimeInterval(59))
    #expect(sync.begin() == nil)
    sync.request(groups: [target], signature: "v1", now: now.addingTimeInterval(60))
    #expect(sync.begin() != nil)
    sync.finish(remaining: true, now: now.addingTimeInterval(60))
    for seconds in [120, 180, 240, 300, 359] {
      sync.request(groups: [target], signature: "v1", now: now.addingTimeInterval(Double(seconds)))
      #expect(sync.begin() == nil)
    }
    sync.request(groups: [target], signature: "v1", now: now.addingTimeInterval(360))
    #expect(sync.begin() != nil)
    sync.finish(remaining: true, now: now.addingTimeInterval(360))
    sync.request(groups: [target], signature: "v1", now: now.addingTimeInterval(660))
    #expect(sync.begin() == nil, "the second failed sweep waits ten minutes")
    sync.refresh()
    #expect(sync.begin() != nil, "new prerequisite bypasses retry backoff")
    sync.finish(now: now.addingTimeInterval(660))
    sync.request(groups: [target], signature: "v1", now: now.addingTimeInterval(960))
    #expect(sync.begin() == nil, "settled work cancels its retry")
  }

  @Test func migrationNormalizesStaleRegistryAndPreservesPendingWork() {
    var sync = ready()
    sync.migrate(from: target, to: "second", orderedBefore: <)
    #expect(sync.begin() == ["second"])
    #expect(sync.request(groups: [target, "second"], signature: "v1").isEmpty)
    sync.finish()
    #expect(sync.begin() == nil)
  }

  @Test func customRetryDelaysSaturateAndRefreshIsConfigurable() {
    var sync = BotCommandSynchronization<String>(refreshInterval: 100, progressDelay: 2, failureDelays: [3, 7])
    var now = Date(timeIntervalSince1970: 1000)
    sync.request(groups: [], signature: "v1", now: now)
    for delay in [3.0, 7.0, 7.0] {
      #expect(sync.begin() == [])
      sync.finish(remaining: true, now: now)
      sync.request(groups: [], signature: "v1", now: now.addingTimeInterval(delay - 1))
      #expect(sync.begin() == nil)
      now = now.addingTimeInterval(delay)
      sync.request(groups: [], signature: "v1", now: now)
    }
    #expect(sync.begin() == [])
    sync.finish(now: now)
    sync.request(groups: [], signature: "v1", now: Date(timeIntervalSince1970: 1100))
    #expect(sync.begin() == [])
    #expect(sync.revision == 2)
  }
}
