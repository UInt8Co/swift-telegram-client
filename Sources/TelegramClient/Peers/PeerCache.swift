import TelegramSchema

/// Resolves peer IDs once on the session that will use them.
///
/// Keep one cache per authorized connection and lookup policy. Access hashes
/// cannot cross accounts or login sessions. Bot lookups start with zero, but
/// subsequent requests must prefer the full hash Telegram returned; callers
/// should use the returned reference for reads, writes and media uploads.
/// <https://core.telegram.org/api/peers#access-hash>
///
/// This caches explicit lookups, not incoming updates. Invalidate a peer when
/// Telegram reports its reference is no longer usable, and discard the cache
/// when replacing the connection. Failed lookups are never cached.
public actor PeerCache {
  private let api: TLClient
  private let lookup: PeerLookup
  private var channels: [Int64: ChannelReference] = [:]
  private var users: [Int64: UserReference] = [:]

  public init(using api: TLClient, lookup: PeerLookup) {
    self.api = api
    self.lookup = lookup
  }

  /// Returns this session's channel reference, resolving it if needed.
  public func channel(_ id: Int64) async throws -> ChannelReference {
    if let cached = channels[id] { return cached }
    let reference = try await PeerResolver.channel(.id(id), lookup: lookup, using: api)
    if reference.accessHash != 0 { channels[id] = reference }
    return reference
  }

  /// Returns this session's user reference, resolving it if needed.
  public func user(_ id: Int64) async throws -> UserReference {
    if let cached = users[id] { return cached }
    let reference = try await PeerResolver.user(id, lookup: lookup, using: api)
    if reference.accessHash != 0 { users[id] = reference }
    return reference
  }

  /// Makes the next channel lookup ask Telegram again.
  public func invalidateChannel(_ id: Int64) {
    channels.removeValue(forKey: id)
  }

  /// Makes the next user lookup ask Telegram again.
  public func invalidateUser(_ id: Int64) {
    users.removeValue(forKey: id)
  }
}
