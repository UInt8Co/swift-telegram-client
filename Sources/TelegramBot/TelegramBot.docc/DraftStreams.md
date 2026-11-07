# Native buttons and draft streams

Compose native button rows and stream ephemeral replies through `TelegramBot`.
Import `TelegramRichText` for the message builder and `TelegramSchema` for TL types.

## Button rows

```swift
let message = RichMessage {
    Paragraph("An action was completed.")
    ButtonRow {
        RichButton.callback("Undo", data: payload, style: .primary)
        RichButton.url("Details", "https://example.com/action")
    }
}
```

`ButtonRow` emits a native button-row page block. Titles are literal text, empty rows emit nothing, and callback data must be 1 to 64 bytes (check outside input with `RichButton.isValidCallbackData`).

## Draft streams

- `DraftStream` is a pure state machine: it decides when a draft is shown, when it is kept alive, and when it settles (after inactivity, at a lifetime limit, when full, or when the user stops it).
- `DraftStreamer<Key>` owns one stream per key and runs the transport. Drafts are real time: at most one request per key is in flight, and changes made meanwhile collapse into a single follow-up carrying the latest content.
- The transport owns the content and batch boundaries. Each generation has a draft ID; use the returned ID to assign entries.
- `DraftStop.parse` recognizes the user's stop action. `DraftClient.show` sends the draft through `messages.setTyping`.

Invariants:

- Settlement is attempted exactly once per generation, even after draft errors, which go to the required `onError` callback.
- Durable delivery, idempotent message IDs, flood-wait handling and restart recovery belong to the owner; nothing is kept across restarts.
- `settleAll()` closes intake and drains every queued generation on shutdown.

Cancellation of `DraftStreamer.run()` stops driving deadlines without draining. Call
`settleAll()` explicitly to close intake and attempt persistence for queued generations.
The concurrency limit bounds transport calls, not retained content or queued generations.
