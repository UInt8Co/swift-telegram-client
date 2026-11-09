# ``TelegramArchive``

Retain boxed TL bytes with a compact, queryable JSON projection.

## Overview

``TLArchive/payload(_:)`` captures the original bytes and a reflected JSON view.
``TLArchivePayload`` is Codable: ordinary encoders write `constructor`, base64
`bytes`, and the opaque `json` string. ``TLArchiveStorage/encode(_:)`` replaces
bytes with `rawSlot` references into a binary sidecar. Reads preserve the bytes
and JSON string verbatim, including unknown layers and malformed JSON views.
The module performs no I/O, creates no tasks, and does not check cancellation.

### Storage compatibility

Compact TL views use `_` for constructors, `_archive` metadata with `version: 1`,
`constructor`, and an optional producing `layer`, and `$rawBytes` placeholders.
Default fields and flag words are omitted from the view; the original TL bytes
remain authoritative. Integer tokens retain Int64 and UInt64 precision.

A sidecar starts with ASCII `TLR1`, followed by a little-endian UInt32 blob
count and, for each blob, a little-endian UInt32 length and those exact bytes.
Zero-length blobs are valid. Slots must each be consumed exactly once; missing,
duplicate, conflicting, out-of-range, and unused slots are rejected. Trailing or
truncated sidecar data is rejected. No sidecar is produced for zero blobs.
The encoder/decoder context key `TLArchiveStorage.raw` is reserved internally.

``TLArchiveStorage/pack(_:)`` converts historical envelopes without decoding TL,
visiting object keys in sorted order and arrays in order. Typed encoding follows
the Encodable value's traversal order, which is not necessarily key order.
``TLArchiveStorage/unpack(_:raw:)`` restores inline bytes without interpreting
the JSON views. These formats and ordering rules are compatibility contracts.

### Retained layers and schema upgrades

``TLArchive/legacyConstructors`` currently supports six layer-231 layouts whose
layer-232 successors only added optional fields: `channel`, `channelFull`,
`inputReplyToMessage`, `messageReplyHeader`, `userFull`, and `wallet.nftItem`.
Layer 233 retains those constructor IDs and layouts; its new user and channel
sidebar flags require no additional substitutions.
Only words rejected by the TL reader as constructors are substituted; matching
integer values inside ordinary fields are unchanged. The original bytes are
never rewritten. Unknown layouts still throw; this is not a general decoder
for every Telegram layer. Layout-changing upgrades require a dedicated decoder.

On **every schema layer bump**, review and update the constructor table, retain
earlier compatible entries, update golden fixtures deliberately, and run all
archive tests. Applications with retained databases must also run their snapshot
decode and migration tests before adopting the new layer. Table membership tests
alone do not prove that historical layouts remain compatible.

``TLArchive/decode(_:from:substitutions:)`` and `TLDecodable.init(retainedTL:substitutions:)`
accept caller substitutions, overriding built-in entries for that call. Cyclic
substitutions fail instead of looping. Like the underlying TL reader, successful
decoding permits trailing bytes; sidecar validation is stricter.

### Presentation and custom types

``TLArchivePayload/fullJSON(registry:)`` reconstructs legacy JSON only when its
compact semantics match the stored view and its layer is absent or current.
Unsupported names, layers, versions, bytes, or mismatches return the stored JSON.
``TLArchiveRegistry/standard`` documents the built-in top-level types. Copy it
and register more TL types to extend presentation without global mutable state:

```swift
import TelegramArchive
import TelegramSchema

var registry = TLArchiveRegistry.standard
registry.register(TL.PeerUser.self)
let payload = try TLArchive.payload(TL.PeerUser(userId: 42))
let json = payload.fullJSON(registry: registry)
```

``TLArchive/prettyPrintedJSON(_:)`` changes only whitespace outside strings and
preserves numeric spellings and escapes. ``ArchiveJSON`` is the archive-specific
tree for schema-free transformations; floating-point parsing does not preserve
the original token spelling.

## Topics

### Encoding and compatibility

- ``TLArchive``
- ``TLArchivePayload``
- ``TLArchiveRegistry``

### Storage and presentation

- ``TLArchiveStorage``
- ``ArchiveJSON``
