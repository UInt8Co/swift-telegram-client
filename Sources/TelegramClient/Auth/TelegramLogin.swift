import MTProtoClientKit
import MTProtoCrypto
import Synchronization
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Signs a user in over a connected, unauthorized session.
///
/// A login is a conversation, not a call: the server asks for a code, then
/// perhaps for a two-step password, and only the application can answer either.
/// So a login is a value the caller builds with its own prompts, and the
/// connection runs it once, at the point it would otherwise have spent a bot
/// token. Conform your own type to drive a flow this package does not ship.
public protocol TelegramUserLogin: Sendable {
  /// Signs in on `api` and returns the user now authorized.
  func signIn(on api: TLClient, app: TelegramApp) async throws -> TL.User
}

/// A login that has to continue on another datacenter — thrown by a login and
/// followed by ``TelegramConnection`` exactly like a `*_MIGRATE_X` answer.
///
/// QR login is the case that needs it: the token a datacenter mints may be
/// accepted only by the one that will home the account, which it names in
/// `auth.loginTokenMigrateTo` rather than in an `rpc_error`.
public struct TelegramLoginMigration: Error, Equatable, Sendable, CustomStringConvertible {
  public var dcID: Int32

  public init(dcID: Int32) {
    self.dcID = dcID
  }

  public var description: String { "the login continues on datacenter \(dcID)" }
}

/// What the server said when it sent a code: how it was delivered, how long
/// until another may be asked for, and the hash that ties the answer to it.
public struct TelegramSentCode: Equatable, Sendable {
  public var type: TL.Auth.SentCodeTypeType
  public var phoneCodeHash: String
  public var nextType: TL.Auth.CodeTypeType?
  public var timeout: Int32?
}

/// What is known about the two-step password when one is required: the hint the
/// user chose, and whether recovery by email is available.
public struct TelegramPasswordPrompt: Equatable, Sendable {
  public var hint: String?
  public var hasRecovery: Bool
  public var emailPattern: String?

  public init(hint: String?, hasRecovery: Bool, emailPattern: String?) {
    self.hint = hint
    self.hasRecovery = hasRecovery
    self.emailPattern = emailPattern
  }
}

/// Obtains the two-step verification password when the server asks for one.
public typealias TelegramPasswordPrompting =
  @Sendable (TelegramPasswordPrompt) async throws -> String

// MARK: - Finishing a sign-in

/// The last step every login shares: turn an `auth.Authorization` into the user
/// it authorized, answering the two-step password challenge if the server
/// raises one.
///
/// `SESSION_PASSWORD_NEEDED` arrives as an `rpc_error` rather than as a
/// constructor, so it is caught rather than switched on — and what follows it is
/// the same conversation on the same session, which is why this wraps the call
/// instead of being a step after it.
enum TelegramLoginCompletion {
  static func user(
    on api: TLClient, password: TelegramPasswordPrompting?,
    authorizing: () async throws -> TL.Auth.AuthorizationType
  ) async throws -> TL.User {
    do {
      return try user(of: try await authorizing())
    } catch let error as MTProtoRPCError where error.message == "SESSION_PASSWORD_NEEDED" {
      guard let password else { throw TelegramLoginError.passwordRequired }
      let prompt = try await api.passwordPrompt()
      return try user(of: try await api.checkPassword(password(prompt)))
    }
  }

  static func user(of authorization: TL.Auth.AuthorizationType) throws -> TL.User {
    switch authorization {
    case .authorization(let value):
      guard case .user(let user) = value.user else {
        throw TelegramClientError.unexpectedAccountKind
      }
      return user
    case .authorizationSignUpRequired:
      throw TelegramLoginError.signUpRequired
    }
  }
}

// MARK: - Phone code

/// Signing in with a phone number and the code Telegram sends to it.
///
/// `code` is asked for once per code sent; to let a user ask for another, call
/// ``resend(on:_:)`` from inside it and answer with the code that arrives.
public struct TelegramPhoneLogin: TelegramUserLogin {
  public var phoneNumber: String
  public var settings: TL.CodeSettings
  /// Obtains the code the user received.
  public var code: @Sendable (TelegramSentCode) async throws -> String
  /// Obtains the two-step verification password, when the account has one. A
  /// login that leaves this out fails on such an account rather than pretending
  /// the password is empty.
  public var password: TelegramPasswordPrompting?

  public init(
    phoneNumber: String, settings: TL.CodeSettings = TL.CodeSettings(),
    code: @escaping @Sendable (TelegramSentCode) async throws -> String,
    password: TelegramPasswordPrompting? = nil
  ) {
    self.phoneNumber = phoneNumber
    self.settings = settings
    self.code = code
    self.password = password
  }

  public func signIn(on api: TLClient, app: TelegramApp) async throws -> TL.User {
    let sent = try await api.invoke(
      TL.Auth.SendCode(
        phoneNumber: phoneNumber, apiId: app.apiID, apiHash: app.apiHash,
        settings: settings))
    let pending: TelegramSentCode
    switch sent {
    case .sentCode(let value):
      pending = TelegramSentCode(
        type: value.type, phoneCodeHash: value.phoneCodeHash, nextType: value.nextType,
        timeout: value.timeout)
    case .sentCodeSuccess(let value):
      // The session was already trusted — an app-supplied token, or a previous
      // login on the same device — so there is no code to ask for.
      return try TelegramLoginCompletion.user(of: value.authorization)
    case .sentCodePaymentRequired:
      throw TelegramLoginError.paymentRequired
    }
    let phoneCode = try await code(pending)
    return try await TelegramLoginCompletion.user(on: api, password: password) {
      try await api.invoke(
        TL.Auth.SignIn(
          phoneNumber: phoneNumber, phoneCodeHash: pending.phoneCodeHash,
          phoneCode: phoneCode))
    }
  }

  /// Asks the server to send the code again, over the next delivery method it
  /// offered. Call it from inside ``code`` when the first one does not arrive.
  public func resend(on api: TLClient, _ sent: TelegramSentCode) async throws
    -> TelegramSentCode
  {
    let again = try await api.invoke(
      TL.Auth.ResendCode(phoneNumber: phoneNumber, phoneCodeHash: sent.phoneCodeHash))
    guard case .sentCode(let value) = again else { throw TelegramLoginError.codeNotResent }
    return TelegramSentCode(
      type: value.type, phoneCodeHash: value.phoneCodeHash, nextType: value.nextType,
      timeout: value.timeout)
  }

  /// Abandons a code that was sent, so it cannot be used.
  @discardableResult
  public func cancel(on api: TLClient, _ sent: TelegramSentCode) async throws -> Bool {
    try await api.invoke(
      TL.Auth.CancelCode(phoneNumber: phoneNumber, phoneCodeHash: sent.phoneCodeHash))
  }
}

// MARK: - QR code

/// Signing in by having an already–signed-in device scan a code.
///
/// The server mints a token, the caller shows it as a QR code, and the other
/// device accepts it. Telegram signals acceptance by pushing `updateLoginToken`
/// rather than by answering, and the documented response to that push is to ask
/// for the token again — so this asks on an interval instead, which needs no
/// update handler wired up on a session that is not yet authorized. Asking again
/// before the token expires returns the same token, so the displayed code is
/// only re-presented when it actually changes.
///
/// A reference type because the flow can outlive one connection: the datacenter
/// that mints the token need not be the one that accepts it, and the token has
/// to survive the migration in between.
public final class TelegramQRLogin: TelegramUserLogin {
  /// The URL to render as a QR code — `tg://login?token=…`, base64url with no
  /// padding, as the scanning client expects it.
  public static func loginURL(token: Data) -> String {
    let base64 = String(
      token.base64EncodedString().compactMap { character in
        switch character {
        case "+": "-"
        case "/": "_"
        case "=": nil
        default: character
        }
      })
    return "tg://login?token=\(base64)"
  }

  /// Ids of users already signed in on this device, which the server excludes
  /// from the accounts the token may authorize.
  public let exceptIDs: [Int64]
  /// Shows the token to the user. Called again whenever the token changes, so a
  /// display that stays up can be refreshed in place.
  public let present: @Sendable (Data) async throws -> Void
  /// Obtains the two-step verification password, when the account has one.
  public let password: TelegramPasswordPrompting?
  /// How often to ask whether the token has been accepted yet.
  public let pollInterval: Duration

  /// A token minted before a migration, to be imported on the datacenter that
  /// named itself. Cleared once spent.
  private let pendingToken = Mutex<Data?>(nil)

  public init(
    exceptIDs: [Int64] = [], pollInterval: Duration = .seconds(2),
    present: @escaping @Sendable (Data) async throws -> Void,
    password: TelegramPasswordPrompting? = nil
  ) {
    self.exceptIDs = exceptIDs
    self.pollInterval = pollInterval
    self.present = present
    self.password = password
  }

  public func signIn(on api: TLClient, app: TelegramApp) async throws -> TL.User {
    try await TelegramLoginCompletion.user(on: api, password: password) {
      try await authorization(on: api, app: app)
    }
  }

  /// Runs the token exchange to an authorization, asking again while the token
  /// is live and unspent.
  private func authorization(on api: TLClient, app: TelegramApp) async throws
    -> TL.Auth.AuthorizationType
  {
    var shown: Data?
    if let carried = pendingToken.withLock({ token -> Data? in
      defer { token = nil }
      return token
    }) {
      // Minted before a migration and already on screen: import it here rather
      // than mint a second one the user has not seen.
      shown = carried
      if let authorization = try await resolve(
        try await api.invoke(TL.Auth.ImportLoginToken(token: carried)), presented: &shown)
      {
        return authorization
      }
    }
    while true {
      let exported = try await api.invoke(
        TL.Auth.ExportLoginToken(
          apiId: app.apiID, apiHash: app.apiHash, exceptIds: exceptIDs))
      if let authorization = try await resolve(exported, presented: &shown) {
        return authorization
      }
      try await Task.sleep(for: pollInterval)
    }
  }

  /// One `auth.LoginToken`. `nil` means the token is live and unspent, so the
  /// caller asks again.
  private func resolve(
    _ token: TL.Auth.LoginTokenType, presented shown: inout Data?
  ) async throws -> TL.Auth.AuthorizationType? {
    switch token {
    case .loginToken(let value):
      if shown != value.token {
        shown = value.token
        try await present(value.token)
      }
      return nil
    case .loginTokenMigrateTo(let value):
      pendingToken.withLock { $0 = value.token }
      throw TelegramLoginMigration(dcID: value.dcId)
    case .loginTokenSuccess(let value):
      return value.authorization
    }
  }
}

// MARK: - Two-step verification

extension TLClient {
  /// Answers the two-step password challenge and finishes the sign-in.
  ///
  /// Public because the check is also how an already–signed-in session proves
  /// the password to the operations that demand it, not only how a login ends.
  public func checkPassword(_ password: String) async throws -> TL.Auth.AuthorizationType {
    let state = try await invoke(TL.Account.GetPassword())
    guard state.hasPassword, let srpID = state.srpId, let srpB = state.srpB,
      let algo = state.currentAlgo
    else { throw TelegramSRPError.noPasswordSet }
    guard
      case .passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow(let kdf) = algo
    else { throw TelegramSRPError.unsupportedPasswordAlgorithm }
    let proof = try TelegramSRP.proof(
      for: password,
      challenge: TelegramSRP.Challenge(
        group: SRP.Group(pBytes: kdf.p, g: kdf.g), salt1: kdf.salt1, salt2: kdf.salt2,
        srpB: srpB, srpID: srpID))
    return try await invoke(
      TL.Auth.CheckPassword(
        password: .inputCheckPasswordSRP(
          TL.InputCheckPasswordSRP(srpId: srpID, A: proof.a, M1: proof.m1))))
  }

  /// What the server will tell a user about their password before asking for it.
  public func passwordPrompt() async throws -> TelegramPasswordPrompt {
    let state = try await invoke(TL.Account.GetPassword())
    return TelegramPasswordPrompt(
      hint: state.hint, hasRecovery: state.hasRecovery,
      emailPattern: state.emailUnconfirmedPattern)
  }

  /// Ends the session and invalidates its authorization.
  @discardableResult
  public func logOut() async throws -> TL.Auth.LoggedOut {
    try await invoke(TL.Auth.LogOut())
  }
}

public enum TelegramLoginError: Error, Equatable, Sendable, CustomStringConvertible {
  case signUpRequired
  case paymentRequired
  case passwordRequired
  case codeNotResent

  public var description: String {
    switch self {
    case .signUpRequired:
      "the phone number has no account; signing one up is not supported here"
    case .paymentRequired: "the server requires a purchase before it will send a code"
    case .passwordRequired:
      "the account has two-step verification and the login was given no way to ask for it"
    case .codeNotResent: "the server did not send another code"
    }
  }
}
