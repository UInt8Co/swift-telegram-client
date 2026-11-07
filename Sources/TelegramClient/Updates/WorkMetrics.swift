#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import TelegramSchema

/// Pending includes the running head, which can retain its captures during retries.
/// Byte estimates describe retained work, not RSS: shared payloads can appear in
/// multiple lanes, and allocator/task overhead is approximate.
public struct WorkMetrics: Sendable, Equatable {
  /// Total pending work, including running heads.
  public var depth = 0
  /// Largest current lane depth, not a historical high-water mark.
  public var maxDepth = 0
  /// Approximate retained bytes across all lanes.
  public var estimatedBytes = 0
  /// Largest current lane byte estimate.
  public var maxEstimatedBytes = 0
  /// Number of nonempty lanes.
  public var laneCount = 0
  /// Age of the oldest retained item.
  public var oldest = Duration.zero
  /// Creates a snapshot; maxima describe the current lanes.
  public init(depth: Int = 0, maxDepth: Int = 0, estimatedBytes: Int = 0,
    maxEstimatedBytes: Int = 0, laneCount: Int = 0, oldest: Duration = .zero) {
    self.depth = depth; self.maxDepth = maxDepth
    self.estimatedBytes = estimatedBytes; self.maxEstimatedBytes = maxEstimatedBytes
    self.laneCount = laneCount; self.oldest = oldest
  }
}

/// A structural estimate for decoded TL/domain value trees when no RawPayload
/// exists. Never serializes data. Used only for the mailbox, at log time.
public enum DecodedSizeEstimate {
  /// Estimates a finite decoded value tree without encoding it. Shared values may be counted twice.
  public static func bytes(_ value: Any) -> Int {
    if let text = value as? String { return 16 + text.utf8.count }
    if let data = value as? Data { return 16 + data.count }
    let mirror = Mirror(reflecting: value)
    if mirror.children.isEmpty { return mirror.displayStyle == .optional ? 0 : 8 }
    return 16 + mirror.children.reduce(0) { $0 + bytes($1.value) }
  }
}
