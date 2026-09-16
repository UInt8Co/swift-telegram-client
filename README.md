# swift-telegram-client

[![CI](https://github.com/UInt8Co/swift-telegram-client/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/UInt8Co/swift-telegram-client/actions/workflows/ci.yml)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FUInt8Co%2Fswift-telegram-client%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/UInt8Co/swift-telegram-client)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FUInt8Co%2Fswift-telegram-client%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/UInt8Co/swift-telegram-client)

A Swift library for Telegram user and bot accounts, with typed `async` APIs,
phone and QR login, session reuse, update helpers, and media transfer.
Uses Telegram's MTProto API, not the HTTP Bot API.

**[API documentation][documentation]** · [DocC overview][overview] · [Telegram method reference][methods]

## Installation

Requires Swift 6.3 or later. Apple minimum deployment targets are macOS 15,
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
Telegram API types and methods.

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

The default session store is in-memory. To keep logins across restarts, implement
`TelegramSessionStore` and pass it as `sessionStore:` with a stable, distinct
`sessionScope:` for each account. Reuse the store and scope when reconnecting,
and protect saved session keys as credentials. `.storedSessionOnly` fails rather
than logging in again when no valid saved session is available.

## Updates, peers, and media

Pass `onPushedUpdates:` to `connect` to receive live updates. The callback does
not recover missed updates automatically: use `UpdateCursor` and
`DifferenceDecoder` with `updates.getDifference`, plus the channel-difference
helpers for channels and supergroups.

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

## License

MIT. See [LICENSE](LICENSE).

[documentation]: https://swiftpackageindex.com/UInt8Co/swift-telegram-client/documentation/telegramclient
[overview]: Sources/TelegramClient/TelegramClient.docc/TelegramClient.md
[methods]: https://core.telegram.org/methods
