import TelegramSchema

/// Named display fields from one live TL value. This does not merge snapshots,
/// select an owner from a response, normalize aliases, or inspect arbitrary metadata.
public struct PeerDisplayText: Equatable, Sendable {
  /// User's first name, preserving empty and absent values.
  public var firstName: String?
  /// User's last name, preserving empty and absent values.
  public var lastName: String?
  /// Group or channel title, including forbidden-peer constructors.
  public var title: String?
  /// Business introduction title, preserving empty and absent values.
  public var businessIntroTitle: String?
  /// Business introduction description, preserving empty and absent values.
  public var businessIntroDescription: String?
  /// Business location address, preserving empty and absent values.
  public var businessAddress: String?

  /// Projects only the supplied user's display names.
  public init(_ user: TL.User) {
    firstName = user.firstName; lastName = user.lastName
  }

  /// Projects only business display fields; surrounding response users are not read.
  public init(_ user: TL.UserFull) {
    businessIntroTitle = user.businessIntro?.title
    businessIntroDescription = user.businessIntro?.description
    businessAddress = user.businessLocation?.address
  }

  /// Projects a basic group or channel title. Empty chats have no title.
  public init(_ chat: TL.ChatType) {
    switch chat {
    case .chat(let value): title = value.title
    case .chatForbidden(let value): title = value.title
    case .channel(let value): title = value.title
    case .channelForbidden(let value): title = value.title
    case .chatEmpty: break
    }
  }
}
