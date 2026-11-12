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

Give the connection a ``ReceivedPeerObservation`` and attach an observer to it:

```swift
let receivedPeers = ReceivedPeerObservation(log: log)
let connection = try await TelegramConnection.connect(
  app: app, authorization: .botToken(token),
  onPushedUpdates: { mailbox.push($0) },
  receivedPeers: receivedPeers)

// A store scoped by the login can only be opened now; nothing received so far
// — the login's own result, an early push — is lost meanwhile.
let store = try PeerStore(account: connection.accountID, dc: connection.endpoint.dcID)
await receivedPeers.attach { peers in
  try await store.record(users: peers.users, chats: peers.chats)
}
```

An observer can just as well be attached before connecting, when its store
does not depend on the login.

### What is observed

- **Every RPC result that can hold a peer**, through ``TelegramConnection/api``:
  whatever method a caller invokes, and `updates.getDifference` /
  `updates.getChannelDifference`, which are results like any other. A method
  sent inside a wrapper (`invokeWithoutUpdates`, `invokeWithLayer`, …) is
  recognised as itself.
- **The connection's own RPCs while connecting** — the login, or the call that
  proves a resumed session.
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
it came with — so a store must never let a `min` object overwrite a hash it
learned from a full one.

``ReceivedPeers/origin`` says what carried them: the pushed container itself,
or the ``ReceivedPeers/Call`` whose result did. A call carries

- ``ReceivedPeers/Call/function`` — the request type, compared with
  ``ReceivedPeers/Call/invokes(_:)``: `call.invokes(TL.Users.GetFullUser.self)`;
- ``ReceivedPeers/Call/result`` — the decoded result the caller receives, so a
  kind of reply is told by its type (`call.result is TL.Users.UserFull` or
  `TL.Messages.ChatFull` for a full-information read) rather than by name;
- ``ReceivedPeers/Call/context`` — whatever the caller attached;
- ``ReceivedPeers/Call/withholdsResultOnFailure`` — whether throwing now can
  still withhold the result from its caller.

### Telling the observer about a call

What a result cannot say — that a lookup is not a sighting, that the caller will
report these peers itself, that a call is safe to make again — the caller says
by attaching a context to the calls it makes:

```swift
let users = try await ReceivedPeers.withContext(Lookup.existenceCheck) {
  try await connection.api.users.getUsers(id: ids)
}
```

The observer reads it back as `peers.call?.context as? Lookup`. The context
follows the task, through transport decorators and child tasks; an inner
`withContext` replaces an outer one.

The schema itself has no notion of which methods change state on the server:
a TL method declares its parameters and its result type, and nothing else. No
reliable read-or-write fact can therefore be generated from it — neither the
`get…` naming convention nor an `Updates` result type separates them
(`messages.getPollResults` returns `Updates`; `account.updateProfile` returns a
`User`). A consumer whose failure policy depends on it names the calls itself:
by context at the call site, or by request type with
``ReceivedPeers/Call/invokes(_:)``.

### Ordering, backpressure and failure

The observer runs **before** what carried the peers is handed on, so a hash is
recorded by the time any code can act on the result or the update:

- For an RPC, once an observer is attached, it runs on the caller's task and
  the result is returned when it returns. Concurrent calls observe
  concurrently, so the observer must be safe to run concurrently with itself; a
  slow observer slows exactly the calls it is observing. If it throws, the call
  throws ``PeerObservationFailure`` instead of returning — **after the server
  already executed it**, so an observer should only throw for a call that is
  safe to make again — or the `CancellationError` it threw.
- Pushes are observed one at a time, in arrival order, and each is handed to
  `onPushedUpdates` only after its observation returned. The server pushes
  regardless of how quickly they are consumed, so a slow observer grows an
  unbounded queue rather than losing pushes.
- **A push is never lost to an observer failure.** The failure is reported to
  the observation's failure handler, with the peers that were not recorded, and
  the push is then handed on all the same: some pushes — a pre-checkout query
  that must be answered within seconds — cannot wait for the difference to
  bring them back.
- Until an observer is attached, results reach their callers at once and their
  peers are held, in order, with every push. Attaching observes them all, hands
  on the held pushes, and only then lets new results be observed inline; a
  result arriving meanwhile waits behind them. A held result's caller already
  has it, so a failure to observe it is reported, not thrown.
- The connection's own RPCs while connecting are never waited for: their peers
  are held, or observed in the background if an observer is attached. An
  observer that fails cannot fail a login the server already accepted, nor make
  the next attempt spend another.

### Testing with the production path

A test with a fake transport builds exactly what a connection does: a
``ReceivedPeerObservation``, a `TLClient` over a ``PeerObservingTransport``
wrapping the fake, and pushes sent through
``ReceivedPeerObservation/push(_:handingOnTo:)``.
``ReceivedPeerObservation/flush()`` waits until every push made so far has been
observed and handed on.

### Cost

A result is decoded twice: once to find its peers, and again by `TLClient` for
the caller, because a transport exchanges bytes rather than values. Only results
of methods that can hold a peer are decoded the extra time.

## Topics

- ``ReceivedPeerObservation``
- ``ReceivedPeers``
- ``ReceivedPeersObserver``
- ``PeerObservingTransport``
- ``PeerObservationFailure``
