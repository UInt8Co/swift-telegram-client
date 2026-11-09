# ``TelegramWidget``

Decode received HTML widgets and read their content without running them.

## Overview

A layer 233 widget carries HTML, inline CSS and script, together with optional
shared and chat state. ``WidgetContent`` decodes a received widget and preserves
its size, identity and capability flags. ``WidgetInspection`` collects plain
text candidates, actions and embedded images for uses such as search, previews,
accessibility text, link prompts and archival.

An inspection is a static reading, not a rendered page. Script can depend on
future state, user input, time or responses that are unavailable to the reader.
The original source, candidate origins, features and truncation status let a
caller decide how much of the widget it has recovered.

## Decode a received widget

Construct ``WidgetContent`` from `TL.MessageMediaWidget` or
`TL.BotInlineMessageWidget`. Both initializers decode the payload and retain the
supplied state. An inline result is a preview, with its request and copy flags
left false. To decode just the HTML, call ``WidgetPayload/html(fromPayload:)``.

The payload must begin with an RFC 1950 zlib header. The decoder inflates with a
32,768-byte output limit, verifies the stream through the compression helper,
and requires strict UTF-8 without NUL bytes. Its typed
``WidgetPayload/DecodingError`` distinguishes:

- `notZlib`: an invalid header, including gzip and raw deflate input.
- `corrupt`: a dictionary request, damaged stream, incomplete stream or checksum
  failure.
- `tooLarge`: inflated HTML exceeds the byte limit.
- `invalidUTF8`: the bytes are not valid UTF-8.
- `containsNUL`: decoded text contains a NUL character.

## Read candidates and their origins

``WidgetInspection`` accepts a ``WidgetContent`` or HTML and optional state
strings. It joins text across inline tags, collapses markup whitespace and ends
candidates at block boundaries, line breaks, list items and table cells. It reads
inline SVG text and template content, skips `noscript` content, and preserves
statically hidden text with the `hiddenText` feature.

Each ``WidgetInspection/Text`` has an ``WidgetInspection/Origin``:

- `markup`: text from HTML or inline SVG.
- `attribute`: a displayed attribute such as `title`, `alt` or `aria-label`.
- `styleContent`: literal CSS generated content, including decoded CSS escapes
  and simple `attr(name)` references.
- `script`: a constant associated with a display sink. Text recovered from an
  HTML fragment carries the sink's origin too.
- `scriptLiteral`: a script string whose use as displayed content was not
  established. Non-JavaScript script blocks contribute JSON string leaves when
  valid JSON, or their whole contents otherwise.
- `state`: a string leaf from supplied JSON state, with a path such as
  `items[2].title`, or the entire state string with a nil path when it is not
  readable as JSON. A top-level JSON string has an empty path. Keys and numeric
  or boolean values do not become text candidates.

``WidgetInspection/Origin/isShown`` is false only for `scriptLiteral`. This is a
source classification; retained hidden markup and state candidates still need
context when presenting a preview. It does not establish visual order or
visibility under every runtime condition.

Markup, displayed attributes and CSS candidates come first in document order,
followed by script contributions and then shared and chat state. Exact duplicate
values with the same origin, and empty or whitespace-only values, are omitted.
A block candidate takes the position of its first non-whitespace text, even when
it spans inline elements with displayed attributes.

Anchor actions pair an attribute-decoded, trimmed destination with the anchor's
text label. Script and handler contributions use one shared analysis budget.
Written HTML fragments are read recursively, with their inline handlers passed
to the analyser; script blocks inside those fragments are retained as literals.

Embedded `data:` images are collected from HTML image sources and source sets,
SVG image references, CSS URLs and script analysis. The reader decodes base64 or
percent-encoded bytes and identifies PNG, GIF, JPEG and WebP by signature, reading
dimensions from their headers where available. SVG data is identified without
dimensions. Other bytes are kept as `unknown`; the declared media type is retained
separately. No image renderer or text recognition is involved.

## Interpret features and limits

``WidgetInspection/Features`` records completeness facts: scripts, animations,
state or context dependencies, unresolved output, graphics and malformed input,
among others. A feature reports a source construct or a limitation of the
reading; it does not prove that a branch runs or that a candidate is visible.
The CSS reader does not compute selector applicability, layout, counters or
quote pairs.

``WidgetInspection/Limits`` caps candidate counts, per-candidate and aggregate
UTF-8 bytes, actions, image counts and aggregate decoded image bytes. Text is cut
on a Swift character boundary. Script token and folding budgets are shared across
all script blocks and handlers; the nesting budget bounds written HTML fragments.
Any dropped or cut content caused by a limit sets
``WidgetInspection/isTruncated``. The JSON reader also bounds depth to 64 and
values to 100,000; a value beyond those bounds falls back to the original string
and marks the reading truncated.

## Example

```swift
import TelegramWidget

let content = WidgetContent(
  html: "<p title='Route information'>Next: <b>Central</b></p><a href='/times'>Times</a>",
  publicData: #"{"route":"7"}"#)
let reading = WidgetInspection(content)

for candidate in reading.texts where candidate.origin.isShown {
  print(candidate.value)
}
for action in reading.actions {
  print(action.kind, action.target ?? "")
}
```
