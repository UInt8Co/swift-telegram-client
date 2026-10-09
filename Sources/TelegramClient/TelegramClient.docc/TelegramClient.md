# ``TelegramClient``

Service-specific device login can implement `TelegramBoundUserLogin` to receive
the live MTProto auth-key and session identifiers. The application validates the
challenge's destination, purpose and profile before signing it with its own key
backend. This package does not store device private keys or define the service's
custom TL namespace.

Sign in to Telegram, follow it wherever it sends you, and read what it pushes
back.

## Overview

`TelegramSchema` is the Telegram API as generated types: every constructor,
every RPC, and a `TLClient` exposing each one as an `async` function. It knows
nothing about what to do with them. This module is that half — the rules a
client has to obey to keep a Telegram session working at all:

- **Authorizing.** A bot token, a phone code, a QR code, or a session stored
  from last time — see ``TelegramAuthorization``.
- **Migration.** A login authorizes on exactly one datacenter, and every other
  answers `USER_MIGRATE_X`. ``TelegramConnection`` follows those; for files,
  where the holding datacenter will not take the original credential at all,
  ``TelegramClientPool`` has the home connection export one.
- **Failures that are not failures.** `FLOOD_WAIT_X` is a delay, not an error,
  and a timed-out request may still have been applied. ``MTProtoDirective``
  classifies an RPC error into what a caller should actually do about it.
- **Updates.** Telegram pushes a partial stream and expects the client to
  notice the gaps and fill them. ``UpdateCursor`` tracks the sequence state and
  ``UpdateHub`` wakes whoever is waiting on a particular channel.

``TelegramConnection/connect(to:app:authorization:sessionStore:sessionScope:onPushedUpdates:timeouts:log:)``
is the entry point, and it needs no addresses: ``TelegramService/production``
carries Telegram's own seeds, and everything after the first `help.getConfig`
uses the datacenter list Telegram publishes.

```swift
import TelegramClient

let connection = try await TelegramConnection.connect(
  app: TelegramApp(apiID: 12345, apiHash: "…"),
  authorization: .botToken("123456:ABC…"))

let me = try await connection.api.users.getUsers(id: [.inputUserSelf(TL.InputUserSelf())])
await connection.disconnect()
```

### Applying pushed updates without a round trip

Most pushes continue the saved sequence exactly and can be applied as they are;
only a gap needs `updates.getDifference` or `updates.getChannelDifference`.
``PushMailbox`` coalesces a burst of pushes into one pass, and
``SequencePositions`` advances past what continues and reports what does not:

```swift
let mailbox = PushMailbox()
let connection = try await TelegramConnection.connect(
  app: app, authorization: authorization,
  onPushedUpdates: { mailbox.push($0) })

var positions = SequencePositions(account: savedCursor, channels: savedChannelPts)
for await _ in mailbox.wakes {
  let batch = mailbox.take()
  // Handle the updates inside batch.pushes, then:
  let gaps = positions.advance(past: batch.pushes.map(PushSequence.init))
  if gaps.account || batch.poll { /* updates.getDifference from positions.account */ }
  for channel in gaps.channels { /* updates.getChannelDifference for channel */ }
  // Save positions.
}
```

Call `mailbox.poll()` from a timer so a quiet connection still catches up now
and then.

### Talking to something that is not Telegram

`TLClient.invoke` is generic over `TLFunction`, so a schema of your own rides
the same connection once it is generated on top of `TelegramSchema` and shares
its `TL` namespace. Point a ``TelegramService`` at your own addresses, key and
layer and none of the machinery above changes.

## Topics

### Connecting

- ``TelegramConnection``
- ``TelegramApp``
- ``TelegramAuthorization``
- ``TelegramService``
- ``TelegramConnectionTimeouts``
- ``TelegramEndpoint``
- ``TelegramDatacenterTarget``
- ``telegramEndpoints(in:forDC:)``
- ``TelegramTransport``

### Logging in

- ``TelegramUserLogin``
- ``TelegramPhoneLogin``
- ``TelegramQRLogin``
- ``TelegramSentCode``
- ``TelegramPasswordPrompt``
- ``TelegramPasswordPrompting``
- ``TelegramBotToken``
- ``TelegramLoginMigration``
- ``TelegramLoginError``

### Keeping a session

- ``TelegramSessionStore``
- ``CachedTelegramSession``
- ``InMemoryTelegramSessionStore``
- ``FileTelegramSessionStore``

### Datacenters

- ``TelegramClientPool``
- ``TelegramDatacenter``
- ``TelegramDatacenterListCache``
- ``TelegramDatacenterLocating``
- ``FetchedDatacenterList``
- ``StoredDatacenterList``
- ``DatacenterListError``

### Peers

- ``PeerResolver``
- ``PeerCache``
- ``PeerLookup``
- ``PeerLocator``
- ``ChannelReference``
- ``UserReference``
- ``ChannelKind``

### Updates

- ``UpdateHub``
- ``UpdateCursor``
- ``DifferenceReading``
- ``DifferenceBatch``
- ``DifferenceDecoder``
- ``ChannelDifferenceBatch``
- ``ChannelDifferenceDecoder``
- ``ChannelHistoryPage``
- ``ChannelHistoryDecoder``
- ``ChannelState``
- ``ChannelUpdateFilter``
- ``ChannelDifferenceError``
- ``PushMailbox``
- ``UpdateSequence``
- ``PushSequence``
- ``SequencePositions``

### Files and media

- ``MediaTransfer``
- ``SourceMedia``
- ``SourceMediaExtractor``
- ``MediaTransferError``

### Errors and what to do about them

- ``TelegramClientError``
- ``MTProtoDirective``
- ``FloodWait``
- ``TransientRPCFailure``
- ``ServerTimeout``
- ``UnreadableReply``

### Caching

- ``ExpiringCache``

### Diagnostics and pacing

- ``TelegramLog``
- ``TelegramSendRate``
