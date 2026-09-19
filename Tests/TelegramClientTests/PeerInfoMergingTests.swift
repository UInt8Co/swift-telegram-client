import TelegramClient
import TelegramSchema
import Testing

@Suite("Reactive peer merging")
struct PeerInfoMergingTests {
  @Test("Min users preserve full names, usernames, relationships, status and ordinary access hashes")
  func fullUserSurvivesMin() {
    let old = TL.User(contact: true, mutualContact: true, attachMenuEnabled: true, botCanEdit: true,
      closeFriend: true, storiesHidden: true, id: 42, accessHash: 123, firstName: "Full", lastName: "Name",
      username: "full_name", phone: "123", photo: .userProfilePhotoEmpty(.init()),
      status: .userStatusOnline(.init(expires: 999)), usernames: [.init(active: true, username: "full_name")])
    let incoming = TL.User(min: true, premium: true, id: 42, accessHash: 999, firstName: "Partial",
      username: "partial", status: .userStatusRecently(.init()))
    let merged = TelegramPeerInfoMerging.user(incoming, cached: .init(user: old))
    #expect(merged.user.firstName == "Full")
    #expect(merged.user.lastName == "Name")
    #expect(merged.user.username == "full_name")
    #expect(merged.user.usernames == old.usernames)
    #expect(merged.user.photo == old.photo)
    #expect(merged.user.status == old.status)
    #expect(merged.user.contact && merged.user.mutualContact && merged.user.botCanEdit)
    #expect(merged.user.closeFriend && merged.user.storiesHidden && merged.user.attachMenuEnabled)
    #expect(merged.user.premium)
    #expect(!merged.user.min)
    #expect(merged.fullAccessHash == 123)
    #expect(TelegramPeerInfoMerging.invalidatesFullUser(previous: old, updated: merged.user))
  }

  @Test("The documented empty-phone exception promotes a min user's access hash")
  func virtualMinHash() {
    let initial = TelegramUserPeerInfo(user: .init(min: true, id: 42, accessHash: 111))
    #expect(initial.fullAccessHash == nil)
    let promoted = TelegramPeerInfoMerging.user(.init(min: true, id: 42, accessHash: 222, phone: ""), cached: initial)
    #expect(promoted.user.min)
    #expect(!promoted.minAccessHash)
    #expect(promoted.fullAccessHash == 222)
    let later = TelegramPeerInfoMerging.user(.init(min: true, id: 42, accessHash: 333, phone: "123"), cached: promoted)
    #expect(later.fullAccessHash == 222)
    #expect(later.user.phone == "123")
    #expect(!later.minAccessHash)
  }

  @Test("Full constructors clear omitted fields while permitted min photos and empty statuses apply")
  func omissionsAndMinExceptions() {
    let old = TL.User(id: 42, accessHash: 123, firstName: "Name", username: "old",
      photo: .userProfilePhotoEmpty(.init()), status: .userStatusEmpty(.init()))
    let min = TelegramPeerInfoMerging.user(.init(min: true, applyMinPhoto: true, id: 42,
      status: .userStatusOnline(.init(expires: 999))), cached: .init(user: old))
    #expect(min.user.photo == nil)
    #expect(min.user.status == .userStatusOnline(.init(expires: 999)))
    let full = TelegramPeerInfoMerging.user(.init(id: 42, firstName: "New"), cached: min)
    #expect(full.user.username == nil)
    #expect(full.user.lastName == nil)
    #expect(full.user.status == nil)
    #expect(full.fullAccessHash == 123)
  }

  @Test("Reactive user updates replace only their named fields and clear removed usernames")
  func reactiveUpdates() throws {
    let original = TL.User(id: 42, accessHash: 123, firstName: "Old", username: "removed", phone: "123")
    let named = try #require(TelegramPeerInfoMerging.applying(.updateUserName(.init(userId: 42,
      firstName: "New", lastName: "Name", usernames: [.init(active: false, username: "inactive"), .init(active: true, username: "new_name")])), to: original))
    #expect(named.username == "new_name")
    #expect(named.firstName == "New")
    #expect(named.accessHash == 123)
    #expect(named.phone == "123")
    let cleared = try #require(TelegramPeerInfoMerging.applying(.updateUserName(.init(userId: 42,
      firstName: "New", lastName: "", usernames: [])), to: named))
    #expect(cleared.username == nil)
    #expect(cleared.usernames == [])
    #expect(TelegramPeerInfoMerging.applying(.updateUserPhone(.init(userId: 43, phone: "x")), to: original) == nil)
  }

  @Test("Channel min hashes cannot replace full ones and hidden-story omissions are preserved")
  func channelMerging() {
    let old = TL.Channel(creator: true, broadcast: true, megagroup: true, storiesHidden: true, id: 42, accessHash: 123,
      title: "Old", photo: .chatPhotoEmpty(.init()), date: 123,
      adminRights: .init(deleteMessages: true, banUsers: true), bannedRights: .init(sendMessages: true, untilDate: 0))
    let incoming = TL.Channel(megagroup: true, min: true, storiesHiddenMin: true, id: 42, accessHash: 999,
      title: "New", photo: .chatPhotoEmpty(.init()), date: 1)
    let merged = TelegramPeerInfoMerging.channel(incoming, cached: .init(channel: old))
    #expect(merged.fullAccessHash == 123)
    #expect(!merged.channel.min)
    #expect(merged.channel.title == "New")
    #expect(merged.channel.storiesHidden)
    #expect(!merged.channel.storiesHiddenMin)
    #expect(merged.channel.creator && merged.channel.broadcast)
    #expect(merged.channel.date == 123)
    #expect(merged.channel.adminRights == old.adminRights)
    #expect(merged.channel.bannedRights == old.bannedRights)
    #expect(!TelegramPeerInfoMerging.invalidatesFullChannel(previous: old, updated: merged.channel))
  }
}
