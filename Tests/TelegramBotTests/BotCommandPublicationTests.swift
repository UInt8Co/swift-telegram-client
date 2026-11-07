import TelegramBot
import TelegramSchema
import Testing

@Suite struct BotCommandPublicationTests {
  private func list(_ signature: String = "v1", language: String = "") -> BotCommandList {
    .init(languageCode: language, commands: [.init(command: "help", description: "Get help")], signature: signature)
  }

  @Test func firstUnchangedAndEditedLists() {
    let desired = ["b": list(), "a": list()]
    #expect(BotCommandPublication<String>().plan(desired: desired, orderedBefore: <).publish == ["a", "b"])
    let record = BotCommandPublication(published: ["a": "v1", "b": "v1"])
    let unchanged = record.plan(desired: desired, orderedBefore: <)
    #expect(unchanged.publish.isEmpty && unchanged.revoke.isEmpty)
    #expect(record.plan(desired: ["a": list("v2"), "b": list("v2")], orderedBefore: <).publish == ["a", "b"])
  }

  @Test func unavailableScopesRetainReceiptsAndPublicationRefusalDoesNotSuppressResets() {
    let record = BotCommandPublication(published: ["a": "v0"], obsolete: ["b"])
    let desired = ["a": list(), "b": list()]
    let unavailable = record.plan(desired: desired, isAvailable: { _ in false }, orderedBefore: <)
    #expect(unavailable.publish.isEmpty && unavailable.revoke.isEmpty)
    let refused = record.plan(desired: desired, canPublish: { $0 != "a" }, orderedBefore: <)
    #expect(refused.publish == ["b"] && refused.revoke.isEmpty)
    #expect(record.plan(desired: [:], canPublish: { _ in false }, orderedBefore: <).revoke == ["a", "b"])
    #expect(record.plan(desired: [:], isAvailable: { _ in false }, orderedBefore: <).revoke.isEmpty)
    #expect(record.plan(desired: [:], orderedBefore: <).revoke == ["a", "b"])
  }

  @Test func failedCleanupRetriesAndDesiredObsoleteListIsRepublished() {
    let record = BotCommandPublication(published: ["a": "v1"], obsolete: ["b"])
    let plan = record.plan(desired: ["a": list()], orderedBefore: <)
    #expect(plan.publish.isEmpty && plan.revoke == ["b"])
    let reinstated = record.plan(desired: ["a": list(), "b": list()], orderedBefore: <)
    #expect(reinstated.publish == ["b"] && reinstated.revoke.isEmpty)
  }

  @Test func languagesHaveIndependentKeysAndSignatures() {
    let record = BotCommandPublication(published: ["scope/en": "v1", "scope/fr": "v1"])
    let desired = ["scope/en": list(language: "en"), "scope/fr": list("v2", language: "fr")]
    #expect(record.plan(desired: desired, orderedBefore: <).publish == ["scope/fr"])
    #expect(desired["scope/fr"]?.languageCode == "fr")
    #expect(desired["scope/fr"]?.commands.first?.command == "help")
  }
}
