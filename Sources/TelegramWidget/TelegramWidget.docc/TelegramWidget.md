# ``TelegramWidget``

Decode received HTML widgets and read them statically.

## Overview

Since layer 233 a message can carry `messageMediaWidget`: a small HTML document
with inline CSS and JavaScript that clients run in a sandbox. ``WidgetContent``
decodes the media's payload (``WidgetPayload``) beside its state and flags, and
``WidgetInspection`` reads it without running it.
