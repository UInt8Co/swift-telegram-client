import TelegramClient
import TelegramSchema
import Testing

@Suite struct PeerDisplayTextTests {
  @Test func projectsOnlyTheProvidedUserNames() {
    let user = TL.User(id: 7, firstName: "First", lastName: "", username: "alias")
    let display = PeerDisplayText(user)
    #expect(display.firstName == "First" && display.lastName == "")
    #expect(display.title == nil && display.businessIntroTitle == nil)
    #expect(PeerDisplayText(TL.User(id: 7)).firstName == nil)
  }

  @Test func businessFieldsDoNotIncludeOtherFullUserMetadata() {
    let full = TL.UserFull(
      id: 7, about: "Biography", settings: .init(), notifySettings: .init(), commonChatsCount: 0,
      businessIntro: .init(title: "Welcome", description: "Open daily"))
    let display = PeerDisplayText(full)
    #expect(
      display.businessIntroTitle == "Welcome" && display.businessIntroDescription == "Open daily")
    #expect(display.firstName == nil && display.title == nil && display.businessAddress == nil)
  }

  @Test func forbiddenChannelsRetainTheirTitles() {
    let channel = TL.ChatType.channelForbidden(.init(id: 1, accessHash: 1, title: "Channel"))
    #expect(PeerDisplayText(channel).title == "Channel")
    #expect(PeerDisplayText(TL.ChatType.chatEmpty(.init(id: 1))).title == nil)
  }
}
