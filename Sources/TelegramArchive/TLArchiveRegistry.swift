#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramSchema

/// Value-scoped top-level decoders for reconstructing reflected archive JSON.
///
/// Registration is local to a copy of the registry; there is no global mutable state.
/// Decoders execute synchronously and do not check cancellation.
public struct TLArchiveRegistry: Sendable {
  private var decoders: [String: @Sendable (Data) throws -> String] = [:]

  /// Creates an empty registry. Copy `standard` to extend the built-in set.
  public init() {}

  /// Registers a TL type, replacing any decoder under the same constructor name.
  /// The default name matches `TLArchive.payload` reflection. Substitutions extend
  /// the retained-layer table for this decoder only; they cannot adapt changed layouts.
  public mutating func register<T: TLDecodable & TLEncodable>(
    _ type: T.Type, constructor: String? = nil, substitutions: [UInt32: UInt32] = [:]
  ) {
    decoders[constructor ?? String(describing: type)] = { bytes in
      try TLArchive.legacyJSON(TLArchive.decode(type, from: bytes, substitutions: substitutions))
    }
  }

  /// Reconstructs a legacy view or throws if the name or TL layout is unsupported.
  public func reflected(_ constructor: String, bytes: Data) throws -> String {
    guard let decoder = decoders[constructor] else { throw TLArchiveStorage.Failure.unsupportedSchema }
    return try decoder(bytes)
  }

  /// The supported top-level types shipped with this version.
  ///
  /// Includes `TL.Message`, `TL.MessageService`, `TL.MessageType`, `TL.EphemeralMessage`,
  /// `TL.MessageReplyHeader`, `TL.Users.UserFull`, `TL.Messages.ChatFull`,
  /// `TL.Messages.MessagesType`, `TL.Payments.SavedStarGifts`, `TL.UserType`,
  /// `TL.ChatType`, `TL.User`, and `TL.UpdateType`. Other types can always be archived;
  /// register their decoder to enable best-effort legacy presentation.
  public static let standard: Self = {
    var registry = Self()
    registry.register(TL.Message.self)
    registry.register(TL.MessageService.self)
    registry.register(TL.MessageType.self)
    registry.register(TL.EphemeralMessage.self)
    registry.register(TL.MessageReplyHeader.self)
    registry.register(TL.Users.UserFull.self)
    registry.register(TL.Messages.ChatFull.self)
    registry.register(TL.Messages.MessagesType.self)
    registry.register(TL.Payments.SavedStarGifts.self)
    registry.register(TL.UserType.self)
    registry.register(TL.ChatType.self)
    registry.register(TL.User.self)
    registry.register(TL.UpdateType.self)
    return registry
  }()
}
