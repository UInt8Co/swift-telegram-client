# swift-telegram-client

[![CI](https://github.com/UInt8Co/swift-telegram-client/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/UInt8Co/swift-telegram-client/actions/workflows/ci.yml)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FUInt8Co%2Fswift-telegram-client%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/UInt8Co/swift-telegram-client)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FUInt8Co%2Fswift-telegram-client%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/UInt8Co/swift-telegram-client)

A Swift library for Telegram user and bot accounts, with typed `async` APIs,
phone and QR login, session reuse, update helpers, and media transfer.
Uses Telegram's MTProto API, not the HTTP Bot API.

**[API documentation][documentation]** · [DocC overview][overview] · [Telegram method reference][methods]

## Installation

Requires Swift 6.4 or later. Apple minimum deployment targets are macOS 15,
iOS 18, tvOS 18, watchOS 11, and Mac Catalyst 18.

Add the package to your `Package.swift` dependencies. Use `main` until a tagged
release is available:

```swift
.package(url: "https://github.com/UInt8Co/swift-telegram-client", branch: "main")
```

Add both products to your target's dependencies:

```swift
.product(name: "TelegramClient", package: "swift-telegram-client"),
.product(name: "TelegramSchema", package: "swift-telegram-client"),
```

`TelegramClient` provides connections and helpers; `TelegramSchema` provides the
Telegram API types and methods. Optional products provide message composition,
rendering, received widgets, bot-account conveniences and TL archival:

| Product | Purpose |
|---|---|
| `TelegramRichText` | Compose outgoing rich messages with a result builder |
| `TelegramMarkup` | Render received messages as compact HTML-style markup |
| `TelegramWidget` | Decode received HTML widgets and read what they show without running them |
| `TelegramBot` | Bot links, commands, menus, peer pickers, group additions, Stars subscriptions, private topics, buttons and draft streams |
| `TelegramArchive` | Retain boxed TL bytes, compact JSON views, and binary sidecars |

`TelegramBot` builds on `TelegramClient`, `TelegramSchema` and `TelegramRichText`.
Its transport helpers use your `TLClient`; applications own persistence and retries.
`PrivateTopicClient.create` throws `PrivateTopicCreationRefusal` for the two recognized
creation refusals; other errors propagate unchanged. `PrivateChatUnreachable` and
`TelegramClient`'s `ForumTopicGone` parse RPC facts without changing thrown errors.
See [the module overview](Sources/TelegramBot/TelegramBot.docc/TelegramBot.md) and
[native buttons and draft streams](Sources/TelegramBot/TelegramBot.docc/DraftStreams.md).

## Quick start

Get an `api_id` and `api_hash` from [my.telegram.org](https://my.telegram.org/apps).
Both user and bot logins require these application credentials. Replace the
placeholders below and run from an async context:

```swift
import TelegramClient
import TelegramSchema

let connection = try await TelegramConnection.connect(
  app: TelegramApp(apiID: 12345, apiHash: "YOUR_API_HASH"),
  authorization: .botToken("YOUR_BOT_TOKEN"))

do {
  let me = try await connection.api.users.getUsers(
    id: [.inputUserSelf(TL.InputUserSelf())])
  print(me)
} catch {
  await connection.disconnect()
  throw error
}
await connection.disconnect()
```

`connect` uses Telegram's production service and handles login-time datacenter
migration; no server addresses are needed. Keep the connection open for as long
as your app needs it, then call `disconnect()`.

Call methods through `connection.api`, grouped by namespace, such as
`api.users.getUsers` and `api.messages.sendMessage`. The [Telegram method
reference][methods] documents parameters and which methods bots can use.

## Authentication and sessions

Choose an `authorization:` value when connecting:

| Account or login method | Authorization |
|---|---|
| Bot | `.botToken("YOUR_BOT_TOKEN")` |
| User, by phone code | `.user(TelegramPhoneLogin(...))` |
| User, by QR code | `.user(TelegramQRLogin(...))` |
| Previously saved session only | `.storedSessionOnly` |

Phone login accepts your app's code-entry callback; QR login accepts a callback
that displays `TelegramQRLogin.loginURL(token:)` as a QR code. Both accept a
`password` callback for two-step verification. See the [login APIs][documentation]
for callback signatures and options.

The default session store is in-memory. To keep logins across restarts, use
`FileTelegramSessionStore` with a dedicated directory and a stable, distinct
`sessionScope:` for each account:

```swift
import Foundation

let sessions = try FileTelegramSessionStore(
  directory: URL(fileURLWithPath: "data/telegram-session"))
let connection = try await TelegramConnection.connect(
  app: TelegramApp(apiID: 12345, apiHash: "YOUR_API_HASH"),
  authorization: .botToken("YOUR_BOT_TOKEN"),
  sessionStore: sessions, sessionScope: "my-bot")
```

The file store atomically saves sessions and datacenter lists, sets directory
permissions to `0700` and file permissions to `0600`, and preserves account and
datacenter separation. It does not encrypt files. Reuse one store per directory;
concurrent processes should use separate directories. You can also implement
`TelegramSessionStore` for a database or keychain. `.storedSessionOnly` fails
rather than logging in again when no valid saved session is available.

A resumed session is proved by `users.getUsers(inputUserSelf)`; no separate ping
is needed. A timeout or transport failure retries the same cached key on a new
connection, at most three attempts with 250 ms and 500 ms backoff. The configured
connect/request budgets apply to each attempt. If **every attempt exhausts its
whole identify budget**, the cached session is discarded with a warning and the
client authorizes again: Telegram can silently ignore messages sealed with a key
it has forgotten. A timeout followed by success keeps the session. Connect-phase
timeouts, closed connections, and other transport failures never count toward
the forgotten-key signal; exhausted retries surface the error and keep the file.
Warning logs name the failed phase (`connect` or `identify`), attempt, and error.
Flood waits, migrations, and unrelated RPC errors are surfaced without this retry.

Explicit server invalidity (`-404`, `AUTH_KEY_UNREGISTERED`, `AUTH_KEY_INVALID`,
`AUTH_KEY_DUPLICATED`, `SESSION_REVOKED`, or `SESSION_EXPIRED`) discards immediately.
An account mismatch also discards: a bot token naming another account replaces
the cached session with that bot's login, and a resumed key identifying another
account triggers fresh authorization. Warnings name both account IDs without
logging credentials. With `.storedSessionOnly`, discarding leaves no stored
session and the call fails instead of logging in. Media connections using
exported authorization continue to accept the home-DC redirect as their resume proof.

Salt corrections are applied by the transport for the live connection. The
current transport API exposes keys only at the initial handshake, so this library
cannot yet persist the corrected salt after resume. A stored salt may therefore
need correction on the next connection; that does not require a new auth key.

## Updates, peers, and media

Pass `onPushedUpdates:` to `connect` to receive live updates. The callback does
not recover missed updates automatically: use `UpdateCursor` and
`DifferenceDecoder` with `updates.getDifference`, plus the channel-difference
helpers for channels and supergroups. `PushMailbox` batches pushes into one
pass, and `SequencePositions` applies pushes that continue the saved `pts`,
`qts` and `seq` directly, reporting only the gaps that need a difference call.

The [API documentation][documentation] covers peer resolution with `PeerResolver`,
additional datacenter connections with `TelegramClientPool`, photo and document
transfer with `MediaTransfer`, and flood-wait handling with `MTProtoDirective`.
The [DocC topic index][overview] is also available in this repository.

Keep a `PeerCache(using: connection.api, lookup: .byID)` for each bot connection
when addressing peers repeatedly by ID (`.inDialogs` supports user dialog lookup).
Use its `channel(_:)` and `user(_:)` references for subsequent requests: a bot's
zero-hash lookup can return a full access hash that its writes need. Invalidate a
rejected reference before retrying, and replace the cache with the connection;
peer hashes cannot be shared across accounts or login sessions.

## Rich messages

`TelegramRichText` builds Telegram's native rich messages — paragraphs, quotes,
collapsible sections, tables and footnotes — from typed components. Text is
always literal, so nothing needs escaping:

```swift
import TelegramRichText

let message = RichMessage {
  Paragraph {
    Text("Build passed").bold()
    Text(" on ")
    Text("main").monospaced()
  }
  Details("2 checks") {
    Table(headers: ["Check", "State"]) {
      Row { Cell("Tests"); Cell("✅") }
      Row { Cell("Lint"); Cell("✅") }
    }
  }
}
_ = try await connection.api.messages.sendMessage(
  peer: peer, message: "", randomId: .random(in: .min ... .max),
  richMessage: message.richMessage)
```

`richMessage` throws `RichMessageValidationError` before sending when content
exceeds Telegram's rich-message limits or has an empty container that Telegram
refuses. See the [TelegramRichText
documentation][rich-text].

## Reading messages as markup

`TelegramMarkup` renders a received `TL.Message` — text entities, rich blocks,
media and buttons — as escaped markup in the style of the Bot API's rich HTML,
for display, logs or a language model's input:

```swift
import TelegramMarkup

let output = MarkupRenderer().render(message)
print(output.markup)  // <b>Hello</b> <a href="https://example.com">world</a>
```

Opaque fields such as callback data and file references are never rendered.
HTML widgets render as an opaque marker unless `widgets: .summary(...)` asks for a
bounded static summary. See the [TelegramMarkup documentation][markup].

## Reading HTML widgets

`TelegramWidget` decodes `messageMediaWidget`'s zlib payload into its HTML, beside
the widget's state and flags, and reads it statically: block text, displayed
attributes, generated CSS content, constants the script provably writes to the
page, links and copy actions, embedded images and state strings, each with its
origin, plus facts about what the reading could not resolve. Nothing is executed
and every step is bounded.

```swift
import TelegramWidget

let content = try WidgetContent(media)  // a received TL.MessageMediaWidget
let inspection = WidgetInspection(content)
for text in inspection.texts where text.origin.isShown { print(text.value) }
```

See the [TelegramWidget documentation][widget].

## Archiving TL values

`TelegramArchive` retains original TL bytes alongside compact reflected JSON,
including exact integer values. `TLArchiveStorage` packs nested Codable archives
into JSON plus validated binary sidecars. Retained-layer decoding supports an
explicit compatibility table; callers can extend constructor substitutions and
register additional top-level types for legacy JSON presentation.

```swift
import TelegramArchive
import TelegramSchema

let payload = try TLArchive.payload(TL.PeerUser(userId: 42))
let stored = try TLArchiveStorage.encode([payload])
let restored = try TLArchiveStorage.decode(
  [TLArchivePayload].self, json: stored.json, raw: stored.raw)
```

See the [TelegramArchive documentation][archive] for storage formats, supported
historical layouts, and the required compatibility checks on every layer bump.

## License

MIT. See [LICENSE](LICENSE).

[documentation]: https://swiftpackageindex.com/UInt8Co/swift-telegram-client/documentation/telegramclient
[overview]: Sources/TelegramClient/TelegramClient.docc/TelegramClient.md
[methods]: https://core.telegram.org/methods
[rich-text]: Sources/TelegramRichText/TelegramRichText.docc/TelegramRichText.md
[markup]: Sources/TelegramMarkup/TelegramMarkup.docc/TelegramMarkup.md
[widget]: Sources/TelegramWidget/TelegramWidget.docc/TelegramWidget.md

[archive]: Sources/TelegramArchive/TelegramArchive.docc/TelegramArchive.md
