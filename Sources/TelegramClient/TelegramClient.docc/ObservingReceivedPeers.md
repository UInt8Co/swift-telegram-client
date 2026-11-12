# Observing received peers

Record the access hash of every user and chat a connection receives, in one
place, without touching any call site.

## Overview

Telegram has no call that answers an access hash for a bare id. A peer's hash
arrives inside whatever mentions it: the `users` and `chats` of an RPC result
or an update container, and a handful of deeper positions — a channel block of
an instant-view page inside a message's web page, the bot of a login-URL
request, a chat invite's chat, the single `user` of `auth.authorization`. A
client that wants to address a peer later by id alone has to keep every one of
them, and any call that skips the bookkeeping loses some.

Pass an observer when connecting, and the connection hands it every one:

```swift
let connection = try await TelegramConnection.connect(
  app: app, authorization: .botToken(token),
  onPushedUpdates: { mailbox.push($0) },
  onReceivedPeers: { peers in
    try await store.record(users: peers.users, chats: peers.chats)
  })
```

### What is observed

- **Every RPC result that can hold a peer**, through ``TelegramConnection/api``:
  whatever method a caller invokes, the authorization during `connect`
  included, and `updates.getDifference` / `updates.getChannelDifference`, which
  are results like any other. A method sent inside a wrapper
  (`invokeWithoutUpdates`, `invokeWithLayer`, …) is recognised as itself.
- **Every pushed `Updates` container**, before it reaches `onPushedUpdates`.
- **Connections a ``TelegramClientPool`` opens** beside the one it was given.

The set of methods and positions is generated from `Schemas/api.json`
(`Scripts/generate-received-peers.ts`), and a test re-derives it from the same
file, so a schema update that adds a position fails the tests until the
generated code is regenerated with it.

Not observed: a `TLClient` built over some other transport (wrap that transport
in ``PeerObservingTransport``), and methods of a schema generated on top of
`TelegramSchema`, whose results this library cannot decode.

The short update forms `updateShortMessage`, `updateShortChatMessage` and
`updateShortSentMessage` name their peers by id only; they carry no object and
so no hash, and nothing is observed for them. When one names a peer the client
has no hash for, fetch the difference, which returns the objects.

### What the observer receives

``ReceivedPeers`` holds the objects exactly as received, in the value's order:
not merged, not deduplicated, not filtered. The same peer can appear twice in
one value, and a `min` object's hash only addresses the peer within the context
it came with — so a store must never let a `min` object overwrite a hash learned
from a full one. ``ReceivedPeers/origin`` says whether the peers came with a
push or with the result of which method.

### Ordering, backpressure and failure

The observer runs **before** what carried the peers is handed on, so a hash is
recorded by the time any code can act on the result or the update:

- For an RPC, the observer runs on the caller's task, and the result is
  returned when it returns. Concurrent calls observe concurrently, so the
  observer must be safe to run concurrently with itself; a slow observer slows
  exactly the calls it is observing. If it throws, the call throws
  ``PeerObservationFailure`` instead of returning — **after the server already
  executed it**, so a caller must not retry a non-idempotent call on that error
  — or the `CancellationError` it threw.
- Pushes are observed one at a time, in arrival order, and each is handed to
  `onPushedUpdates` only after its observation returned. The server pushes
  regardless of how quickly they are consumed, so a slow observer grows an
  unbounded queue rather than losing pushes. A push whose observer throws is
  dropped with a warning: the difference carries the same update, and its
  peers, through an observed RPC.

Without an observer, nothing changes: results are returned as before and
pushes reach `onPushedUpdates` synchronously, as they arrive.

### Cost

A result is decoded twice: once to find its peers, and again by `TLClient` for
the caller, because a transport exchanges bytes rather than values. Only results
of methods that can hold a peer are decoded the extra time.

## Topics

- ``ReceivedPeers``
- ``ReceivedPeersObserver``
- ``PeerObservingTransport``
- ``PeerObservationFailure``
