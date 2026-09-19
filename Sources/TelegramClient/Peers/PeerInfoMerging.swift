import TelegramSchema

/// The virtual `min_access_hash` bit cannot reliably be recovered from a merged
/// User's `min` flag. Persist it alongside the TL value in a peer database.
public struct TelegramUserPeerInfo: Equatable, Sendable {
  public var user: TL.User
  public var minAccessHash: Bool

  public init(user: TL.User, minAccessHash: Bool? = nil) {
    self.user = user
    self.minAccessHash = minAccessHash ?? (user.min && user.phone != "")
  }

  public var fullAccessHash: Int64? { minAccessHash ? nil : user.accessHash }
}

public struct TelegramChannelPeerInfo: Equatable, Sendable {
  public var channel: TL.Channel
  public var minAccessHash: Bool

  public init(channel: TL.Channel, minAccessHash: Bool? = nil) {
    self.channel = channel
    self.minAccessHash = minAccessHash ?? channel.min
  }

  public var fullAccessHash: Int64? { minAccessHash ? nil : channel.accessHash }
}

/// Pure merge rules for persistent peer stores. Values must belong to the same
/// authorized account and login session: access hashes are not portable.
/// See https://core.telegram.org/api/peers and /constructor/user.
public enum TelegramPeerInfoMerging {
  public static func user(_ incoming: TL.User, cached: TelegramUserPeerInfo?) -> TelegramUserPeerInfo {
    guard let cached, cached.user.id == incoming.id else { return .init(user: incoming) }
    let old = cached.user
    var result = incoming
    var minHash = incoming.min && incoming.phone != ""
    if incoming.accessHash == nil || (minHash && old.accessHash != nil && !cached.minAccessHash) {
      result.accessHash = old.accessHash
      minHash = cached.minAccessHash
    }
    if incoming.min {
      result.min = old.min
      result.contact = old.contact
      result.mutualContact = old.mutualContact
      result.attachMenuEnabled = old.attachMenuEnabled
      result.botCanEdit = old.botCanEdit
      result.closeFriend = old.closeFriend
      result.storiesHidden = old.storiesHidden
      result.storiesMaxId = old.storiesMaxId
      if !old.min {
        result.firstName = old.firstName
        result.lastName = old.lastName
        result.username = old.username
        result.usernames = old.usernames
        result.phone = old.phone
        if !incoming.applyMinPhoto { result.photo = old.photo }
        if let status = old.status, case .userStatusEmpty = status {} else { result.status = old.status }
      }
    }
    return .init(user: result, minAccessHash: minHash)
  }

  public static func channel(_ incoming: TL.Channel, cached: TelegramChannelPeerInfo?) -> TelegramChannelPeerInfo {
    guard let cached, cached.channel.id == incoming.id else { return .init(channel: incoming) }
    let old = cached.channel
    var result = incoming
    if incoming.min {
      // channel.min has a strict field allowlist. Membership and administrator
      // rights omitted from the minimal constructor must never be erased.
      result = old
      result.title = incoming.title
      result.megagroup = incoming.megagroup
      result.color = incoming.color
      result.photo = incoming.photo
      result.username = incoming.username
      result.usernames = incoming.usernames
      result.hasGeo = incoming.hasGeo
      result.noforwards = incoming.noforwards
      result.emojiStatus = incoming.emojiStatus
      result.hasLink = incoming.hasLink
      result.slowmodeEnabled = incoming.slowmodeEnabled
      result.scam = incoming.scam
      result.fake = incoming.fake
      result.gigagroup = incoming.gigagroup
      result.forum = incoming.forum
      result.level = incoming.level
      result.restricted = incoming.restricted
      result.restrictionReason = incoming.restrictionReason
      result.joinToSend = incoming.joinToSend
      result.joinRequest = incoming.joinRequest
      result.verified = incoming.verified
      result.defaultBannedRights = incoming.defaultBannedRights
      result.signatureProfiles = incoming.signatureProfiles
      result.autotranslation = incoming.autotranslation
      result.broadcastMessagesAllowed = incoming.broadcastMessagesAllowed
      result.monoforum = incoming.monoforum
      result.forumTabs = incoming.forumTabs
      result.linkedMonoforumId = incoming.linkedMonoforumId
      result.sendPaidMessagesStars = incoming.sendPaidMessagesStars
      result.botVerificationIcon = incoming.botVerificationIcon
      result.accessHash = incoming.accessHash
    }
    var minHash = incoming.min
    if incoming.accessHash == nil || (incoming.min && old.accessHash != nil && !cached.minAccessHash) {
      result.accessHash = old.accessHash
      minHash = cached.minAccessHash
    }
    if incoming.min { result.min = old.min }
    if !incoming.min && incoming.storiesHiddenMin {
      result.storiesHidden = old.storiesHidden
      result.storiesHiddenMin = old.storiesHiddenMin
    }
    return .init(channel: result, minAccessHash: minHash)
  }

  /// Apply only the fields owned by the update, never replacing other cached
  /// data with defaults. Returns nil for an unrelated update or different ID.
  public static func applying(_ update: TL.UpdateType, to user: TL.User) -> TL.User? {
    var result = user
    switch update {
    case .updateUserStatus(let value) where value.userId == user.id:
      result.status = value.status
    case .updateUserName(let value) where value.userId == user.id:
      result.firstName = value.firstName
      result.lastName = value.lastName
      result.usernames = value.usernames
      result.username = value.usernames.first(where: \.active)?.username
    case .updateUserPhone(let value) where value.userId == user.id:
      result.phone = value.phone
    case .updateUserEmojiStatus(let value) where value.userId == user.id:
      result.emojiStatus = value.emojiStatus
    default: return nil
    }
    return result
  }

  public static func invalidatesFullUser(previous old: TL.User, updated new: TL.User) -> Bool {
    old.deleted != new.deleted || old.bot != new.bot || old.premium != new.premium ||
      old.botCanEdit != new.botCanEdit || old.botInfoVersion != new.botInfoVersion ||
      old.usernames != new.usernames || old.photo != new.photo ||
      ((old.botCanEdit || new.botCanEdit) && old.username != new.username)
  }

  public static func invalidatesFullChannel(previous old: TL.Channel, updated new: TL.Channel) -> Bool {
    old.megagroup != new.megagroup || old.scam != new.scam || old.hasLink != new.hasLink ||
      old.slowmodeEnabled != new.slowmodeEnabled || old.fake != new.fake || old.gigagroup != new.gigagroup ||
      old.joinToSend != new.joinToSend || old.joinRequest != new.joinRequest || old.forum != new.forum ||
      old.restrictionReason != new.restrictionReason || old.level != new.level || old.photo != new.photo ||
      old.username != new.username || old.usernames != new.usernames
  }
}
