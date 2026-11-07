import MTProtoClientKit

/// A target user was deactivated. Authorization failures are deliberately excluded.
public enum TargetUserDeactivated {
  /// Recognizes only code 400 INPUT_USER_DEACTIVATED and USER_DEACTIVATED.
  /// Code 401 describes the caller's authorization, not the requested target.
  public static func describes(_ error: any Error) -> Bool {
    guard let rpc = error as? MTProtoRPCError, rpc.code == 400 else { return false }
    return rpc.message == "INPUT_USER_DEACTIVATED" || rpc.message == "USER_DEACTIVATED"
  }
}

/// A request was refused as made, or the client could not resolve its target.
/// This fact includes *all* 4xx errors, including authorization and flood waits;
/// it does not establish permanence or authorize skipping or retrying work.
public enum RequestRefusal {
  /// Tests RPC status or a missing/unsupported client peer reference.
  public static func describes(_ error: any Error) -> Bool {
    if let rpc = error as? MTProtoRPCError { return (400..<500).contains(rpc.code) }
    if let client = error as? TelegramClientError {
      switch client {
      case .peerNotFound, .userNotFound, .channelRequired, .monoforumUnsupported, .missingAccessHash: return true
      default: return false
      }
    }
    return false
  }
}

/// The RPC server reported a positive or negative 5xx status.
public enum RPCServerFailure {
  /// Recognizes 500...599 and -599 ... -500. This says nothing about whether
  /// the operation was applied or whether retrying it is safe.
  public static func describes(_ error: any Error) -> Bool {
    guard let rpc = error as? MTProtoRPCError else { return false }
    return (500...599).contains(rpc.code) || (-599 ... -500).contains(rpc.code)
  }
}

/// A narrow composite of server timeouts, internal errors and client timeouts.
/// This does not change the semantics of ``TransientRPCFailure`` or ``ServerTimeout``.
public enum ServerTransientFailure {
  /// Accepts -503, 500, -500, and the client's per-request timeout. Other 5xx,
  /// disconnections, refusals, flood waits and cancellation are excluded.
  /// The caller must independently establish that repeating its operation is safe.
  public static func describes(_ error: any Error) -> Bool {
    if let client = error as? MTProtoClientError { return client == .timeout }
    if TransientRPCFailure.describes(error) { return true }
    guard let rpc = error as? MTProtoRPCError else { return false }
    return rpc.code == 500 || rpc.code == -500
  }
}

/// Operation-specific peer access facts, not a universal membership predicate.
public enum PeerAccessFailure {
  /// The operation cannot use the supplied peer reference or requires rights
  /// the caller lacks. CHAT_ADMIN_REQUIRED does not imply lost membership.
  public static func operationUnavailable(_ error: any Error) -> Bool {
    if let rpc = error as? MTProtoRPCError {
      return ["CHANNEL_PRIVATE", "CHANNEL_PUBLIC_GROUP_NA", "CHANNEL_INVALID", "CHAT_ID_INVALID", "PEER_ID_INVALID", "CHAT_ADMIN_REQUIRED", "USER_NOT_PARTICIPANT"].contains(rpc.message)
    }
    if let client = error as? TelegramClientError {
      switch client {
      case .peerNotFound, .channelRequired, .monoforumUnsupported, .missingAccessHash, .userNotFound: return true
      default: break
      }
    }
    return false
  }

  /// A getChannels/getChats target is unavailable through this reference.
  /// Missing admin rights, unsupported monoforums and missing users are excluded.
  /// An invalid reference alone is not proof of lost membership.
  public static func groupUnavailable(_ error: any Error) -> Bool {
    if let rpc = error as? MTProtoRPCError, rpc.message == "CHAT_ADMIN_REQUIRED" { return false }
    if let client = error as? TelegramClientError {
      switch client {
      case .monoforumUnsupported, .userNotFound: return false
      default: break
      }
    }
    return operationUnavailable(error)
  }

  /// The user reference is absent, invalid, or targets a deactivated user.
  /// This is not a statement about private-message delivery permissions.
  public static func userUnavailable(_ error: any Error) -> Bool {
    if case .userNotFound = error as? TelegramClientError { return true }
    return (error as? MTProtoRPCError)?.message == "USER_ID_INVALID" || TargetUserDeactivated.describes(error)
  }

  /// A context-based lookup was refused or its peer reference is unavailable.
  /// Includes non-flood 4xx (even authorization failures); callers retain their
  /// authorization handling. This does not prove the context message was deleted.
  public static func contextRefused(_ error: any Error) -> Bool {
    operationUnavailable(error) || userUnavailable(error)
      || (RequestRefusal.describes(error) && MTProtoDirective(error)?.wait == nil)
  }
}
