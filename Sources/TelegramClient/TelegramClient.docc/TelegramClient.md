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

``TelegramConnection/connect(to:app:authorization:sessionStore:sessionScope:onPushedUpdates:receivedPeers:timeouts:log:)``
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

- ``PeerID``
- ``MessageAddress``
- ``ChatAdministrator``
- ``ChatAdminLookup``
- ``ChatAdminLookupError``
- ``ForumTopics``
- ``ForumTopicGone``

- <doc:ObservingReceivedPeers>
- ``ReceivedPeerObservation``
- ``ReceivedPeers``
- ``ReceivedPeersObserver``
- ``PeerObservingTransport``
- ``PeerObservationFailure``

- ``PeerResolver``
- ``PeerCache``
- ``PeerLookup``
- ``PeerLocator``
- ``ChannelReference``
- ``UserReference``
- ``ChannelKind``

### Updates

- ``GroupMigration``

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

### Request admission and retry

Share a ``FloodGate`` across transports for an account to reject calls during
method flood holds. Its default exclusions assume destination writes are paced
by ``TelegramSendRate``; pass an empty set if they are not. ``RequestLimiter``
bounds concurrency and spaces starts. ``ExponentialRetry`` leaves repeatability
and error selection to its caller; error facts alone do not make a mutation safe
to repeat.

- ``FloodGate``
- ``FloodJitter``
- ``RequestLimiter``
- ``ExponentialRetry``
- ``TargetUserDeactivated``
- ``RequestRefusal``
- ``PeerAccessFailure``
- ``RPCServerFailure``
- ``ServerTransientFailure``

### Ordered intake and recovery

``PushMailbox`` supports arrival-ordered bounded drains without bounding retained backlog.
``OrderedWorkQueue`` serializes each key and supports selective barriers; ``WorkReceipt``
waiters and ``ConcurrencyPermitPool`` waiters cancel independently. These are in-memory
primitives, not a durable or exactly-once delivery system. Applications own deduplication,
checkpoint schemas, retry policy and retention limits.

``ChannelRecovery`` commits only after successful handling and verified backfill coverage.
``ChannelBackfill`` reads exact IDs but cannot reconstruct deleted or intermediate events.
``RecoverySchedule`` accepts application poll intervals, and ``CheckpointWriter`` coalesces
revisioned snapshots. ``FileKeyValueStore`` persists opaque bytes with compatible hex-key
filenames; ``SessionInspection`` reports stored-session status without credentials.

- ``OrderedWorkQueue``
- ``WorkReceipt``
- ``WorkReceipt/Completion``
- ``ConcurrencyPermitPool``
- ``WorkMetrics``
- ``DecodedSizeEstimate``
- ``ChannelBackfill``
- ``ChannelRecovery``
- ``ChannelRecovery/ReadResult``
- ``RecoverySchedule``
- ``CheckpointWriter``
- ``FileKeyValueStore``
- ``FileIOExecutor``
- ``SessionInspection``

### Peer observations and link destinations

`PeerSightings` provides partial reactive observations and message access contexts.
`ChannelParticipantLookup` proves absence only after a complete participant traversal.
`ForumTopics.TopicIDPolicy` distinguishes raw headers from validated reply targets.
Link parsing separates destination recognition from application URL canonicalization.

- ``PeerSightings``
- ``ChannelParticipantLookup``
- ``ParticipantLookupError``
- ``ReplyResolver``
- ``TelegramUsername``
- ``TelegramLink``
- ``TelegramLinkDestination``
- ``ProfileMusic``
- ``PeerDisplayText``

### Stickers and emoji

Metadata caches retain lightweight projections and support caller-selected lifetimes
and capacities. Featured-pack traversal requires a user account and performs only reads.

- ``StickerSetCache``
- ``CustomEmojiCache``
- ``EmojiStatus``
- ``TrendingStickerSet``
- ``TrendingStickerSource``

### Group service events

Inspect received TL service messages for joins and membership refresh signals.

- ``GroupServiceEvents``

### Reusing message content and context

`SentMessages` correlates request random IDs with send/forward receipts and
exposes freshness only as an explicitly tolerant heuristic. `MessageReplies`
constructs replies from caller-selected source and destination context.
`ReusableMedia` converts supported received resources without fetching them;
unsupported or incomplete media is reported separately from RPC rejection facts.

- ``SentMessages``
- ``SentMessageError``
- ``MessageReplies``
- ``ReusableMedia``
- ``MediaReuseError``
- ``MediaReferences``
- ``MessageContentRejection``

``MediaReferences`` converts received photos and documents to input references,
preserving IDs, access hashes and file-reference bytes.

### Pure request and peer projections

`RPCRequestSummary` names a request's TL method, through any `invokeWith…`
wrappers, and the peer it leads with, without exposing payloads or access hashes. `MessageContextPeer` builds references from caller-validated history
messages. `TelegramPeerInfoMerging` transforms full peer information and versioned
basic-group participants; the caller owns persistence and invalidation. `SavedGiftText`
projects gift text in source order with caller-selected filtering and input limits.

- ``RPCRequestSummary``
- ``MessageContextPeer``
- ``SavedGiftText``
- ``TelegramPeerInfoMerging``
- ``TelegramPeerInfoMerging/BasicGroupUpdate``
- ``TelegramPeerInfoMerging/fullUser(_:applying:)``
- ``TelegramPeerInfoMerging/fullChannel(_:applying:)``
- ``TelegramPeerInfoMerging/basicGroup(_:applying:version:count:delta:)``
- ``TelegramPeerInfoMerging/basicGroupParticipants(_:applying:previousVersion:version:)``
- ``TelegramPeerInfoMerging/participantID(_:)``
