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

### Safety

Text escapes `&`, `<` and `>`, and attribute values also escape `"`, so text
from a message can never become markup. Media contents, callback data, file
references, access hashes and other opaque fields are never rendered.
``MarkupRenderer/visibleText(_:)`` recovers the text without tags.

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
