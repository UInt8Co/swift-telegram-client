# swift-telegram-client

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FUInt8Co%2Fswift-telegram-client%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/UInt8Co/swift-telegram-client)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FUInt8Co%2Fswift-telegram-client%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/UInt8Co/swift-telegram-client)

A [Telegram](https://core.telegram.org/api) client in Swift: the whole current
API layer as generated types, and the client that knows what to do with them —
logging in, following datacenter migrations, reading updates, moving files.

```swift
.package(url: "https://github.com/UInt8Co/swift-telegram-client", from: "1.0.0")
```

## What this is

[swift-mtproto](https://github.com/UInt8Co/swift-mtproto) and
[swift-nio-mtproto](https://github.com/UInt8Co/swift-nio-mtproto) implement the
*protocol*: TL serialization, the crypto, the transport, the encrypted session.
They know nothing about users, chats or messages. This package is the layer
above — it knows Telegram.

```swift
import TelegramClient

let connection = try await TelegramConnection.connect(
  app: TelegramApp(apiID: 12345, apiHash: "…"),
  authorization: .botToken("123456:ABC…"))

let me = try await connection.api.users.getUsers(id: [.inputUserSelf(TL.InputUserSelf())])
try await connection.api.messages.sendMessage(peer: peer, message: "hello", randomId: .random())
await connection.disconnect()
```

No addresses are named because none are needed: `TelegramService.production`
carries Telegram's own bootstrap set, and everything after the first
`help.getConfig` uses the datacenter list Telegram publishes.

| Module | What it is |
|---|---|
| `TelegramSchema` | The current API layer, generated: every type, every RPC, and a `TLClient` exposing each one as an `async` function grouped by namespace |
| `TelegramClient` | Connections, logging in, datacenter migration and pooling, update differences, peer resolution, file transfer, and the rules for `FLOOD_WAIT`/`*_MIGRATE` |

## Logging in

Four ways, all through the same `authorization:` argument.

```swift
// A bot.
.botToken("123456:ABC…")

// A user, by phone code — and by password when the account has one.
.user(TelegramPhoneLogin(
  phoneNumber: "+15550100",
  code: { sent in await ask("Code sent by \(sent.type):") },
  password: { prompt in await ask("Password (hint: \(prompt.hint ?? "none")):") }))

// A user, by QR code scanned from an already–signed-in device.
.user(TelegramQRLogin(present: { token in
  show(qr: TelegramQRLogin.loginURL(token: token))
}))

// Whatever was authorized last time, and nothing else.
.storedSessionOnly
```

Pass a `sessionStore:` and the negotiated session is kept, so the next run
resumes instead of logging in again — which matters, because logging in is what
earns an application a flood wait. `InMemoryTelegramSessionStore` is the default;
conform `TelegramSessionStore` to keep sessions anywhere you like.

Two-step verification is [SRP-6a](https://core.telegram.org/api/srp). Both halves
of it live in swift-mtproto — `TelegramSRP` computes the proof, `SRP` verifies it
— so `checkPassword` is only the RPC around them.

## Migration, pooling and files

A login authorizes on exactly one datacenter, and everything else answers it
`USER_MIGRATE_X`. `TelegramConnection` follows those. Files are the awkward case:
`upload.getFile` answers `FILE_MIGRATE_X`, and the datacenter that holds the file
will not accept the original credential at all — so `TelegramClientPool` opens
that connection the only way it can be opened, by having the home connection
export an authorization for it.

```swift
let pool = TelegramClientPool(
  main: connection, app: app, datacenters: datacenters, sessionStore: store)
let transfer = MediaTransfer(source: pool, destination: connection.api)
let media = try await transfer.transfer(sourceMedia, destination: channel)
```

## Beyond Telegram's schema

`TLClient.invoke` is generic over `TLFunction`, so a schema of your own rides the
same connection. Generate it on top of this one and the two share a single `TL`
namespace:

```sh
mtproto-gen-swift --schema-url my-schema.json --output Sources/MySchema \
  --mode types --root-namespace-module TelegramSchema
```

```swift
import MySchema  // re-exports TelegramSchema

try await connection.api.invoke(TL.My.Method(…))
```

Use `--mode types` rather than `--mode client`: the `TLClient` facade is this
package's, and one is enough. Point `TelegramService` at your own addresses, key
and layer to talk to a server that is not Telegram at all.

## Regenerating the schema

`Sources/TelegramSchema` is generated and committed; `Schemas/api.json` is the
pinned schema it came from, so a plain run reproduces the tree exactly.

```sh
Scripts/generate-schema.sh                      # from the pinned schema
Scripts/generate-schema.sh --fetch --layer 230  # re-pin from Telegram's published schema
Scripts/generate-schema.sh --from-mtcute ../mtcute
```

The last form needs [Deno](https://deno.com); the others do not. Regenerating
rewrites `Package.swift`'s generated-target region, so a new TL namespace needs
no manifest edit.

## License

MIT. See [LICENSE](LICENSE).
