import TelegramSchema

/// Immediate precheckout extraction and concurrent query handling.
public enum PrecheckoutQueries {
  /// Runs every handler concurrently with no bound on in-flight handlers.
  /// Completion order is unspecified; slow handlers do not block later queries.
  /// Finishing intake also cancels handlers; this method waits for them to exit.
  /// Non-cancellation failures are reported through `onError`.
  /// Cancellation stops intake and cancels every in-flight handler.
  public static func run(
    _ queries: AsyncStream<TL.UpdateBotPrecheckoutQuery>,
    handle: @escaping @Sendable (TL.UpdateBotPrecheckoutQuery) async throws -> Void,
    onError: @escaping @Sendable (TL.UpdateBotPrecheckoutQuery, any Error) -> Void
  ) async {
    await withDiscardingTaskGroup { group in
      for await query in queries {
        guard !Task.isCancelled else { break }
        group.addTask {
          do { try await handle(query) } catch  where !Task.isCancelled {
            onError(query, error)
          } catch {}
        }
      }
      group.cancelAll()
    }
  }

  /// Extract immediately at push intake so a busy ordinary update loop does
  /// not consume Telegram's ten-second window before the handler starts.
  public static func from(_ container: TL.UpdatesType) -> [TL.UpdateBotPrecheckoutQuery] {
    let updates: [TL.UpdateType]
    switch container {
    case .updates(let value): updates = value.updates
    case .updatesCombined(let value): updates = value.updates
    case .updateShort(let value): updates = [value.update]
    default: return []
    }
    return updates.compactMap { update in
      if case .updateBotPrecheckoutQuery(let query) = update { return query }
      return nil
    }
  }
}
