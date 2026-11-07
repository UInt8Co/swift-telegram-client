# ``TelegramBot``

Bot-account conveniences built on native Telegram types and the caller’s `TLClient`.
Callers own authorization, pacing, persistence and retries. Transport methods propagate
errors and cancellation; returned updates remain the caller’s responsibility.

## Topics

### Links

- ``BotLink``

### Payments

- ``StarsInvoice``
- ``StarsInvoiceError``
- ``StarsClient``
- ``StarsPaymentReceipt``
- ``PrecheckoutQueries``

### Private-chat topics

- ``PrivateTopics``
- ``PrivateTopicClient``
- ``PrivateTopicError``
- ``CreatedPrivateTopic``

### Native buttons

- ``RichButton``
- ``ButtonRow``
- ``RichButtonBuilder``

### Draft streams

- <doc:DraftStreams>
- ``DraftClient``
- ``DraftClientError``
- ``DraftStop``
- ``DraftStreamPolicy``
- ``DraftSettleReason``
- ``DraftStreamStep``
- ``DraftStream``
- ``DraftStreamTransport``
- ``DraftStreamOperation``
- ``DraftStreamer``
