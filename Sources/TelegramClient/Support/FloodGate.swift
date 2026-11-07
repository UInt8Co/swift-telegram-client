import MTProtoClientKit
import Synchronization

/// Thread-safe method-level flood admission. Share one instance across transports
/// for one account. Separate instances have independent deadlines. This gate never
/// sleeps or sends: callers record server waits and check admission before sending.
public final class FloodGate: Sendable {
  private struct Entry {
    var until: Duration
    var index: Int
  }
  private struct State {
    var deadlines: [String: Entry] = [:]
    var keys: [String] = []
    var cursor = 0

    mutating func remove(_ key: String) {
      guard let entry = deadlines.removeValue(forKey: key) else { return }
      let last = keys.removeLast()
      if entry.index < keys.count {
        keys[entry.index] = last
        deadlines[last]?.index = entry.index
      }
    }

    // Incremental pruning visits one unrelated method per RPC, even if the
    // flooded method is never called again. Constant work, no full scans.
    mutating func prune(at now: Duration) {
      guard !keys.isEmpty else { return }
      cursor %= keys.count
      let key = keys[cursor]
      if let entry = deadlines[key], entry.until <= now { remove(key) }
      else { cursor += 1 }
    }
  }

  private let state = Mutex(State())
  private let excludedMethods: Set<String>
  private let now: @Sendable () -> Duration
  private let randomUnit: @Sendable () -> Double

  /// Creates a gate. `now` must be monotonic and thread-safe, with an arbitrary
  /// but stable origin. Random samples are clamped to 0...1. Neither callback
  /// runs under the state lock. Pass an empty exclusion set unless another
  /// component owns destination pacing for the default excluded methods.
  public init(excludedMethods: Set<String> = FloodGate.sendRateMethods,
    now: (@Sendable () -> Duration)? = nil,
    randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    let origin = ContinuousClock.now
    self.now = now ?? { origin.duration(to: .now) }
    self.randomUnit = randomUnit
    self.excludedMethods = excludedMethods
  }

  /// Methods normally paced per destination by ``TelegramSendRate``.
  /// The default exclusion set assumes the caller installs that pacing.
  /// In particular, forwardMessages names its source first, and deleteMessages
  /// has no peer at all. Neither should hold every destination.
  public static let sendRateMethods: Set<String> = [
    "channels.deleteMessages", "channels.editBanned",
    "ephemeral.deleteMessage", "ephemeral.editMessage", "ephemeral.sendMessage",
    "messages.createForumTopic", "messages.deleteChatUser", "messages.deleteMessages",
    "messages.deleteTopicHistory", "messages.editForumTopic", "messages.editMessage",
    "messages.forwardMessages", "messages.hideChatJoinRequest", "messages.sendMedia",
    "messages.sendMessage", "messages.setTyping", "messages.updatePinnedMessage", "messages.uploadMedia",
  ]

  /// Whether this instance applies method-level admission to a method.
  public func gates(_ method: String) -> Bool {
    !excludedMethods.contains(method)
  }

  /// Returns a local 420 FLOOD_WAIT error while the method is held. The rounded,
  /// independently jittered wait does not extend the stored deadline. Expired
  /// entries are pruned incrementally; admission does not reserve a send slot.
  public func rejection(for method: String) -> MTProtoRPCError? {
    let current = now()
    let remaining: Duration? = state.withLock { state in
      state.prune(at: current)
      guard gates(method), let entry = state.deadlines[method] else { return nil }
      guard entry.until > current else { state.remove(method); return nil }
      return entry.until - current
    }
    guard let remaining else { return nil }
    // Independently jitter each retry as well as the shared deadline, so
    // callers observing the same remaining wait do not all wake together.
    let parts = FloodJitter.wait(for: remaining, randomUnit: randomUnit).components
    let seconds = max(1, min(Int64.max - 2, parts.seconds) + (parts.attoseconds > 0 ? 1 : 0))
    return MTProtoRPCError(code: 420, message: "FLOOD_WAIT_\(seconds)")
  }

  /// Extends a method deadline by the supplied server wait plus jitter. Shorter
  /// waits never shorten an existing deadline. Excluded methods are ignored.
  public func record(method: String, wait: Duration) {
    guard gates(method) else { return }
    let current = now()
    let until = current + FloodJitter.wait(for: wait, randomUnit: randomUnit)
    state.withLock { state in
      state.prune(at: current)
      if let entry = state.deadlines[method] {
        state.deadlines[method]?.until = max(entry.until, until)
      } else {
        state.deadlines[method] = Entry(until: until, index: state.keys.count)
        state.keys.append(method)
      }
    }
  }

  /// Number of stored deadlines, including entries not yet incrementally pruned.
  public var deadlineCount: Int { state.withLock { $0.deadlines.count } }
}
