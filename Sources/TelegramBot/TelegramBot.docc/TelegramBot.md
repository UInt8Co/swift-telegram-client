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

### Commands and menus

Command parsing preserves argument text and accepts every username of a bot
with several. Publication plans accept caller-owned keys,
signatures and receipts; callers resolve scopes, execute RPCs and persist successful
results. Synchronization coalesces requests with configurable refresh and retry delays.
Menu writes serialize per key; overlapping calls return before the active publisher finishes.

- ``BotCommandParser``
- ``ParsedBotCommand``
- ``BotCommandList``
- ``BotCommandPublication``
- ``BotCommandSynchronization``
- ``BotCommandMenuState``
- ``BotCommandMenus``

### Group additions and peer selection

These helpers decode events without granting access or asserting current membership.

- ``BotGroupAdditionEvent``
- ``RequestedPeerPicker``

### Reusing message content and context

- ``EphemeralReplies``
