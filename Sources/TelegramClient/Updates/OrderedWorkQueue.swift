/// FIFO work per key, with independent workers for different keys and optional selective barriers.
/// Receipts acknowledge successful completion, not durable or exactly-once delivery. Operations
/// may run again after retry and must be safe to repeat. A failed head fails its queued successors.
/// Stop cancels workers and waits for them; operations and injected sleeps must cooperate.
public actor OrderedWorkQueue<Key: Hashable & Sendable> {
  /// A cancellable, repeatable unit of work.
  public typealias Operation = @Sendable () async throws -> Void
  private struct Job {
    var operation: Operation
    var completion: WorkReceipt.Completion
    var received: ContinuousClock.Instant
    var estimatedBytes: Int
  }
  private final class Lane {
    var jobs: [Job?] = []
    var head = 0
    var estimatedBytes = 0
    var task: Task<Void, Never>?
  }
  private var lanes: [Key: Lane] = [:]
  private let observer: @Sendable (Int, Int, Int) -> Void
  private let nextWait: @Sendable (Duration) -> Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var depth = 0
  private var bytes = 0
  private func publishCounts() { observer(depth, lanes.count, bytes) }
  private var barrier: WorkReceipt?
  private let barrierIncludes: @Sendable (Key) -> Bool
  private var stopped = false
  private let retry: @Sendable (any Error, Duration) -> Duration?
  private let failed: @Sendable (any Error) async -> Void

  /// Creates a queue. The retry callback selects a delay or refuses retry. Backoff starts
  /// at one second and advances through `nextWait`. The observer receives depth, lane count,
  /// and approximate retained bytes on the actor; it must not block or reenter synchronously.
  public init(barrierIncludes: @escaping @Sendable (Key) -> Bool = { _ in true }, retry: @escaping @Sendable (any Error, Duration) -> Duration?,
    failed: @escaping @Sendable (any Error) async -> Void,
    nextWait: @escaping @Sendable (Duration) -> Duration = { ExponentialRetry.nextWait(after: $0) },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    observer: @escaping @Sendable (Int, Int, Int) -> Void = { _, _, _ in }) {
    self.observer = observer
    self.nextWait = nextWait
    self.sleep = sleep
    self.barrierIncludes = barrierIncludes
    self.retry = retry
    self.failed = failed
  }

  /// Enqueues work. A barrier waits for all earlier barriers and the last receipt in each selected lane; subsequent
  /// selected work waits for that barrier. Unselected non-barrier work remains independent. Submissions
  /// after stop return failed receipts. Cancelling a receipt waiter does not cancel its work.
  public func submit(_ key: Key, received: ContinuousClock.Instant = .now,
        estimatedBytes: Int = 0, barrier isBarrier: Bool = false, _ operation: @escaping Operation) -> WorkReceipt {
    let completion = WorkReceipt.Completion()
    let receipt = completion.receipt
    // Chain barriers even when their own lanes are excluded.
    let dependencies = isBarrier ? lanes.filter { barrierIncludes($0.key) }.values.compactMap { $0.jobs.last.flatMap { $0 }?.completion.receipt } + [barrier].compactMap { $0 }
      : (barrierIncludes(key) ? [barrier].compactMap { $0 } : [])
    // Approximate receipt/closure storage plus retained dependency references.
    let job = Job(operation: {
      for dependency in dependencies { try await dependency.wait() }
      try Task.checkCancellation()
      try await operation()
    }, completion: completion, received: received,
     estimatedBytes: max(0, estimatedBytes) + MemoryLayout<Job>.stride + 96 + dependencies.count * 8)
    if stopped {
      Task { await completion.finish(.failure(CancellationError())) }
      return receipt
    }
    if isBarrier { barrier = receipt }
    let lane: Lane
    if let existing = lanes[key] { lane = existing }
    else { lane = Lane(); lanes[key] = lane }
    lane.jobs.append(job)
    lane.estimatedBytes += job.estimatedBytes
    depth += 1; bytes += job.estimatedBytes
    publishCounts()
    if lane.task == nil { lane.task = Task { await self.run(key) } }
    return receipt
  }

  private func run(_ key: Key) async {
    while let lane = lanes[key], lane.head < lane.jobs.count, let job = lane.jobs[lane.head] {
      var wait = Duration.seconds(1)
      do {
        while true {
          do {
            try Task.checkCancellation()
            try await job.operation()
            break
          } catch {
            guard !Task.isCancelled, let delay = retry(error, wait) else { throw error }
            try await sleep(delay)
            wait = nextWait(wait)
          }
        }
        await job.completion.finish(.success(()))
      } catch {
        await job.completion.finish(.failure(error))
        if !Task.isCancelled { await failed(error) }
        if let lane = lanes.removeValue(forKey: key) {
          depth -= lane.jobs.count - lane.head; bytes -= lane.estimatedBytes
          publishCounts()
          for job in lane.jobs.compactMap({ $0 }) {
            await job.completion.finish(.failure(error))
          }
        }
        return
      }
      guard let current = lanes[key] else { return }
      current.estimatedBytes -= job.estimatedBytes
      depth -= 1; bytes -= job.estimatedBytes
      current.jobs[current.head] = nil
      current.head += 1
      if current.head == current.jobs.count { lanes.removeValue(forKey: key); publishCounts(); return }
      publishCounts()
      if current.head >= 256 && current.head * 2 >= current.jobs.count {
        current.jobs.removeFirst(current.head)
        current.head = 0
      }
    }
  }

  /// Returns current retained work and age; estimates include running heads.
  public func metrics(now: ContinuousClock.Instant = .now) -> WorkMetrics {
    // Recovery work can enqueue ahead of an older received push, so its
    // running head need not have the oldest receipt timestamp.
    var result = WorkMetrics(laneCount: lanes.count)
    for lane in lanes.values {
      let depth = lane.jobs.count - lane.head
      result.depth += depth
      result.maxDepth = max(result.maxDepth, depth)
      result.estimatedBytes += lane.estimatedBytes
      result.maxEstimatedBytes = max(result.maxEstimatedBytes, lane.estimatedBytes)
      for job in lane.jobs[lane.head...] {
        if let job { result.oldest = max(result.oldest, job.received.duration(to: now)) }
      }
    }
    return result
  }

  /// Permanently stops admission and cancels all workers, waiting for cooperative shutdown.
  public func stop() async {
    stopped = true
    let tasks = lanes.values.compactMap(\.task)
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
  }
}
