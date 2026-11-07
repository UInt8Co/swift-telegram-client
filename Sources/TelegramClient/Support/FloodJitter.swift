/// Shared by RPC admission and callers scheduling a flood retry. Never shortens
/// Telegram's wait; adds uniform 0...min(10 s, 10% of the wait + 2 s).
public enum FloodJitter {
  /// Adds bounded positive jitter, clamping negative waits to zero and random
  /// samples to 0...1. The random source is called synchronously once.
  public static func wait(for duration: Duration,
              randomUnit: @Sendable () -> Double = { Double.random(in: 0...1) }) -> Duration {
    let duration = max(.zero, duration)
    let parts = duration.components
    let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    let extra = min(10, seconds * 0.1 + 2) * min(1, max(0, randomUnit()))
    return duration + .seconds(extra)
  }
}
