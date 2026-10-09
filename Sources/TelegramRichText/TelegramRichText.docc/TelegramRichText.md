# ``TelegramRichText``

Compose Telegram's native rich messages with a Swift result builder.

## Overview

A ``RichMessage`` is a tree of `TL.PageBlockType` values: paragraphs, quotes,
collapsible sections, tables and references, built from typed components.
Content stays structured from composition to the wire, so there is no HTML or
Markdown to escape: text is always literal.

```swift
import TelegramRichText

let results = [("Document", "✅"), ("Image", "❌")]
let message = RichMessage {
  Paragraph {
    Text("Upload finished").bold()
    Text(" — see ")
    Text("the log").link(to: "https://example.com/log")
  }
  Details("\(results.count) files") {
    Table(headers: ["File", "State"]) {
      for (name, state) in results {
        Row {
          Cell(name)
          Cell(state)
        }
      }
    }
  }
}

_ = try await connection.api.messages.sendMessage(
  peer: peer, message: "", randomId: .random(in: .min ... .max),
  richMessage: message.richMessage)
```

Builders accept `if`, `if`/`else` and `for` at every level. Inline modifiers
(``InlineContent/bold()``, ``InlineContent/italic()``,
``InlineContent/monospaced()``, ``InlineContent/link(to:)``) nest as native
formatting when chained. Conform your own types to ``InlineContent`` or
``BlockContent`` to make reusable components out of existing ones.

### Sending

``RichMessage/richMessage`` is the sending boundary. It converts the blocks to
their input form and throws ``RichMessageValidationError`` before a request is
made when content exceeds Telegram's
[rich message limits](https://core.telegram.org/bots/api#rich-message-limits) —
nesting depth, block count, text length, attachments, table columns — or uses
formatting that cannot be sent. ``RichMessage/inputMessage(blocks:rtl:photos:documents:users:)``
applies the same checks to blocks you assembled yourself and lets you attach
photos, documents and users.

``RichMessage/text`` is a plain-text projection for logs, accessibility and
assertions. ``Text/fragments(_:limit:)`` splits long text without breaking a
Unicode scalar, for table cells with a length limit.

### Copying received content

Received rich text contains entities Telegram detected (mentions, hashtags,
commands, auto-links) that are not valid input constructors.
``RichMessage/inputBlocks(_:)`` replaces them with their formatted text,
throughout nested blocks and captions, and clears received webpage IDs.
Media and user references are left alone; supply the matching input objects
yourself. ``Hashtag`` sends its text with automatic entity detection, as TDLib
does.

### Footnotes and references

`footnote(_:named:)` attaches a definition to
inline content. References are numbered in reading order, and each named
definition is placed once in a footer. Wrap content in ``References`` to collect
the definitions into a collapsed, numbered list instead, with superscript links
from the text:

```swift
let message = RichMessage {
  References("Sources") {
    Paragraph {
      Text("Alex").link(to: "https://t.me/alex")
        .reference(Hashtag("#user42"), named: "alex")
      Text(" opened the issue.")
    }
  }
}
```

## Topics

### Messages

- ``RichMessage``
- ``RichMessageValidationError``

### Inline content

- ``InlineContent``
- ``Text``
- ``Inline``
- ``Hashtag``
- ``CustomEmoji``
- ``InlineBuilder``

### Blocks

- ``BlockContent``
- ``Paragraph``
- ``Preformatted``
- ``Blockquote``
- ``Details``
- ``References``
- ``RichBlockBuilder``

### Tables

- ``Table``
- ``Row``
- ``Cell``
- ``RowBuilder``
- ``CellBuilder``
