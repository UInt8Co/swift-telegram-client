# ``TelegramMarkup``

Render received Telegram messages as compact, HTML-style markup.

## Overview

``MarkupRenderer`` is the reverse of Telegram's HTML parser: entity offsets and
TL constructor trees become nested tags in the style of the Bot API's
[rich HTML](https://core.telegram.org/bots/api#rich-html-style). Use it to show,
log, search or index message content, or to hand a message to a language model
as text that keeps its formatting, media and buttons.

```swift
import TelegramMarkup

let renderer = MarkupRenderer(
  customEmoji: [5_368_324_170_671_202_286: .init(title: "Party", shortName: "party_pack")])
let output = renderer.render(message)  // a received TL.Message
print(output.markup)
// <b>Launch</b> today <tg-emoji pack="Party" pack-name="party_pack">🎉</tg-emoji>
// <img/>
// <tg-button-row><tg-button type="url" url="https://example.com">Open</tg-button></tg-button-row>
```

A message renders its text, rich-message blocks, media and reply markup in that
order, one part per line. Each part can also be rendered on its own:
``MarkupRenderer/render(text:entities:)`` takes text with entities, and the
other `render(_:)` overloads take page blocks, rich text, media or reply markup.

``MarkupRenderer/Output/isComplete`` is false when an entity range is invalid
(outside the text, or splitting a UTF-16 surrogate pair) or nesting exceeds
``MarkupRenderer/maximumDepth``. The rest of the content still renders; whether
incomplete content is acceptable is the caller's decision.

### Tags

Telegram's own tags are used where they exist: `b`, `i`, `u`, `s`, `code`,
`pre`, `blockquote` (with `expandable`), `a`, `tg-spoiler`, `tg-emoji`,
`tg-math`, headings, `p`, lists, `table`, `details`, `figure`, `img`, `video`,
`audio`, and `tg-button` inside `tg-button-row`. Entities Telegram detects from
the text itself — mentions, hashtags, URLs, commands, cashtags, phone and card
numbers — stay plain text, and a link whose label is its own target is shown as
plain text.

Content with no Telegram HTML uses `tg-*` tags: `tg-sticker`, `tg-poll` (an
answer someone other than the author added carries `added-by`), `tg-contact`,
`tg-venue`, `tg-preview` for link previews, `tg-story`, `tg-game`,
`tg-invoice`, `tg-dice`, `tg-giveaway`, `tg-paid-media`, `tg-todo`,
`tg-keyboard` for reply keyboards, and `tg-media` for anything unsupported.
Widgets default to `<tg-media type="widget"/>`. Enable a static summary with
``MarkupRenderer/widgets`` as described below.

### Safety

Text escapes `&`, `<` and `>`, and attribute values also escape `"`, so text
from a message can never become markup. Callback data, file references, access
hashes and other opaque fields are never rendered. Widget summaries include
inspected content and state only when explicitly enabled.
``MarkupRenderer/visibleText(_:)`` recovers the text without tags.

### Widget summaries

Opt in when you want a bounded reading of a received widget, without running its
script or rendering its HTML:

```swift
let renderer = MarkupRenderer(widgets: .summary(.init(
  maximumCharacters: 4096, maximumValueCharacters: 512)))
let output = renderer.render(message)
```

``WidgetSummaryLimits/inspection`` controls the underlying `WidgetInspection`.
The reading collects candidates; runtime input and future state can change what
a viewer sees. Feature flags describe source constructs and limits of the
reading, and do not establish that a particular branch runs.

The outer `tg-widget` element includes `id` for a shared widget, nonzero `width`
and `height`, and the boolean flags `copy`, `can-query` and `background-query`
when set. `features` lists inspection feature names in declaration order, using
kebab case (for example, `script timers reads-state canvas-text`). Empty feature
sets omit the attribute. An undecodable payload yields a self-closing element
with `invalid` and the available identity, size and capability attributes.

Children appear on separate lines, in this priority order:

- `tg-widget-action`: `type` is `anchor`, `open-link`, `open-telegram-link`,
  `copy-text`, `request`, `wallet-send-transaction` or `wallet-sign-data`.
  A constant argument becomes `target`; otherwise the action has `unresolved`.
  An anchor label becomes element text when available.
- `tg-widget-text`: markup text has no extra attributes. Display attributes use
  `from="attribute"` and `name`; CSS content uses `from="style"`; script display
  sinks use `from="script"` and `sink` (for example, `inner-html`). These texts
  retain inspection order.
- `tg-widget-state`: `name` is `public-data` or `chat-data`; a JSON leaf also has
  `path`, including an empty path for a top-level string.
- `tg-widget-literal`: script strings whose display was not established. Values
  equal to shown text, shorter than three characters, or without a letter or
  number are omitted. The remaining strings retain inspection order.
- `tg-widget-images`: `count` is the number of inspected embedded images;
  `formats` lists their distinct format names in alphabetical order. Image
  bytes are omitted.

Content values collapse whitespace and are trimmed before cutting to
``WidgetSummaryLimits/maximumValueCharacters`` characters, including a final
`…` when cut. Text and attributes then use the renderer's usual escaping.
Nonpositive value limits keep empty values. Limits count Swift characters,
rather than UTF-8 bytes.

``WidgetSummaryLimits/maximumCharacters`` counts the whole escaped element,
including tags, newlines and the `truncated` attribute. The first child that
would exceed the budget stops all remaining children. The header and closing
tag are always written, even when their size alone exceeds the budget.
`truncated` reports inspection limits, value cuts or the element budget.
These flags do not change ``MarkupRenderer/Output/isComplete``.

### Packs

Custom emoji and stickers carry `pack` and `pack-name` attributes when you
supply pack metadata through ``MarkupRenderer/customEmoji`` and
``MarkupRenderer/stickerSets``. Looking packs up — with `messages.getStickerSet`,
for example — is left to you.

## Topics

### Rendering

- ``MarkupRenderer``
- ``MarkupRenderer/Output``
- ``MarkupRenderer/Pack``

### Widgets

- ``WidgetRendering``
- ``WidgetSummaryLimits``
