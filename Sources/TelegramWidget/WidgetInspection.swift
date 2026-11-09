/// A static reading of a widget: what its HTML, script and state can be seen
/// to show and do, without running its script or rendering it.
///
/// Telegram's HTML widgets (`messageMediaWidget`, layer 233) are small HTML
/// documents with inline CSS and JavaScript that clients run in a sandbox. A
/// widget can build its whole interface at runtime, so no static reading is a
/// faithful picture of what a viewer sees. The inspection collects candidates
/// instead, each with its ``Origin``: text in the markup, display attributes,
/// generated CSS content, constants the script provably writes to the page or
/// passes to a link or clipboard call, and the widget's state. ``Features``
/// records what the inspection could not resolve and which runtime inputs the
/// widget depends on, so a reader can judge how complete the picture is.
///
/// Everything is bounded by ``Limits``; ``isTruncated`` is true when a limit
/// cut the reading short.
public struct WidgetInspection: Equatable, Sendable {
  /// Candidate text, in document order where the source gives one: markup and
  /// attributes first as they appear, then script, then state.
  public var texts: [Text]
  /// Links, clipboard copies, bot requests and wallet calls the widget can make.
  public var actions: [Action]
  /// Embedded `data:` images.
  public var images: [Image]
  public var features: Features
  /// True when a limit stopped the inspection before it read everything.
  public var isTruncated: Bool

  public init(
    texts: [Text] = [], actions: [Action] = [], images: [Image] = [],
    features: Features = [], isTruncated: Bool = false
  ) {
    self.texts = texts
    self.actions = actions
    self.images = images
    self.features = features
    self.isTruncated = isTruncated
  }

  /// Inspects a decoded widget with its current state.
  public init(_ content: WidgetContent, limits: Limits = .init()) {
    self.init(html: content.html, publicData: content.publicData, chatData: content.chatData, limits: limits)
  }

  /// Inspects widget HTML and, when given, its state strings.
  public init(html: String, publicData: String? = nil, chatData: String? = nil, limits: Limits = .init()) {
    var inspector = WidgetInspector(limits: limits)
    inspector.inspect(html: html, publicData: publicData, chatData: chatData)
    self = inspector.result
  }
}

extension WidgetInspection {
  public struct Limits: Equatable, Sendable {
    /// Most text candidates kept.
    public var maximumTexts: Int
    /// Longest single candidate, in UTF-8 bytes; longer values are cut.
    public var maximumTextBytes: Int
    /// Total UTF-8 bytes of all candidates.
    public var maximumTotalTextBytes: Int
    /// Most actions kept.
    public var maximumActions: Int
    /// Most images kept; each image's bytes count toward ``maximumImageBytes``.
    public var maximumImages: Int
    public var maximumImageBytes: Int
    /// Script tokens read across all scripts and handlers.
    public var maximumScriptTokens: Int
    /// Evaluation steps the constant folder may spend across all scripts.
    public var maximumFoldingSteps: Int
    /// Nested decodings (an HTML fragment inside a script string inside
    /// markup, a base64 string inside that) followed before giving up.
    public var maximumNesting: Int

    public init(
      maximumTexts: Int = 1_024, maximumTextBytes: Int = 2_048, maximumTotalTextBytes: Int = 65_536,
      maximumActions: Int = 128, maximumImages: Int = 32, maximumImageBytes: Int = 65_536,
      maximumScriptTokens: Int = 100_000, maximumFoldingSteps: Int = 50_000, maximumNesting: Int = 3
    ) {
      self.maximumTexts = maximumTexts
      self.maximumTextBytes = maximumTextBytes
      self.maximumTotalTextBytes = maximumTotalTextBytes
      self.maximumActions = maximumActions
      self.maximumImages = maximumImages
      self.maximumImageBytes = maximumImageBytes
      self.maximumScriptTokens = maximumScriptTokens
      self.maximumFoldingSteps = maximumFoldingSteps
      self.maximumNesting = maximumNesting
    }
  }

  /// One candidate string. Values are plain text: entities and escapes are
  /// decoded, markup is never included.
  public struct Text: Equatable, Hashable, Sendable {
    public var value: String
    public var origin: Origin
    public init(_ value: String, origin: Origin) {
      self.value = value
      self.origin = origin
    }
  }

  /// Where a candidate came from.
  public enum Origin: Equatable, Hashable, Sendable {
    /// A text node of the static markup, HTML or inline SVG (`<text>`).
    case markup
    /// A displayed attribute of the static markup: `title`, `alt`,
    /// `aria-label`, `placeholder`, `value` or `label`.
    case attribute(String)
    /// A string in CSS `content`, in a `<style>` block or a `style` attribute.
    case styleContent
    /// A constant the script writes to a display sink. Text of an HTML
    /// fragment written with `innerHTML` and the like has this origin too.
    case script(Sink)
    /// A string literal of a script or inline handler that the inspection did
    /// not see reach a sink: possibly shown, possibly a selector, a key or an
    /// unused branch.
    case scriptLiteral
    /// A string in the widget's state: the whole value, or a JSON string leaf
    /// with its path (`items[2].title`) when the state parses as JSON.
    case state(StateField, path: String?)

    /// Whether the candidate is known to be shown (or offered) to a viewer
    /// once the widget runs with the state given. Only ``scriptLiteral`` is not.
    public var isShown: Bool { self != .scriptLiteral }
  }

  /// A script call or property that puts text on screen.
  public enum Sink: String, Equatable, Hashable, Sendable {
    case textContent, innerText, innerHTML, outerHTML, insertAdjacentHTML, insertAdjacentText
    case createTextNode, documentWrite, append, canvasText, setAttribute, nodeValue, value
  }

  public enum StateField: String, Equatable, Hashable, Sendable {
    case publicData, chatData
  }

  /// Something a viewer's tap can make the widget do.
  public struct Action: Equatable, Hashable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
      /// `<a href>` in the static markup or a written HTML fragment.
      case anchor
      /// `TelegramWidget.openLink` or `window.open`.
      case openLink
      /// `TelegramWidget.openTelegramLink`.
      case openTelegramLink
      /// `TelegramWidget.copyText`.
      case copyText
      /// `TelegramWidget.request`, a query to the widget's bot.
      case request
      case walletSendTransaction, walletSignData
    }
    public var kind: Kind
    /// The URL, copied text or request data; nil when it is not a constant.
    public var target: String?
    /// The anchor's text, when the action is an anchor.
    public var label: String?
    public init(kind: Kind, target: String?, label: String? = nil) {
      self.kind = kind
      self.target = target
      self.label = label
    }
  }

  /// An embedded `data:` image.
  public struct Image: Equatable, Hashable, Sendable {
    public enum Format: String, Equatable, Hashable, Sendable { case png, jpeg, gif, webp, svg, unknown }
    /// Format by the bytes' signature, not the declared media type.
    public var format: Format
    public var declaredMediaType: String
    public var width: Int?
    public var height: Int?
    /// The decoded bytes.
    public var data: [UInt8]
    public init(format: Format, declaredMediaType: String, width: Int?, height: Int?, data: [UInt8]) {
      self.format = format
      self.declaredMediaType = declaredMediaType
      self.width = width
      self.height = height
      self.data = data
    }
  }

  /// Facts about how the widget builds what it shows.
  public struct Features: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// `<script>` blocks or inline `on*` handlers are present.
    public static let script = Features(rawValue: 1 << 0)
    /// `setTimeout`, `setInterval` or `requestAnimationFrame`.
    public static let timers = Features(rawValue: 1 << 1)
    /// CSS animations or transitions.
    public static let styleAnimation = Features(rawValue: 1 << 2)
    /// Reads `publicData` or `chatData`, or listens for their changes.
    public static let readsState = Features(rawValue: 1 << 3)
    /// Asks to watch shared state (`watchPublicData`).
    public static let watchesState = Features(rawValue: 1 << 4)
    /// `localStorage` or `sessionStorage`.
    public static let storage = Features(rawValue: 1 << 5)
    /// Reads the viewer, the chat type, or whether it is a forward or preview.
    public static let readsContext = Features(rawValue: 1 << 6)
    /// `Math.random`, `crypto` randomness, `Date` or `performance.now`.
    public static let clockOrRandomness = Features(rawValue: 1 << 7)
    /// Writes markup or text the inspection could not resolve to a constant.
    public static let unresolvedOutput = Features(rawValue: 1 << 8)
    /// A link, copy, request or wallet call whose argument is not a constant.
    public static let unresolvedAction = Features(rawValue: 1 << 9)
    /// `eval`, `Function`, or a string passed to a timer.
    public static let dynamicCode = Features(rawValue: 1 << 10)
    /// `String.fromCharCode` or `String.fromCodePoint`.
    public static let characterCodes = Features(rawValue: 1 << 11)
    /// `atob`.
    public static let base64 = Features(rawValue: 1 << 12)
    /// `decodeURIComponent`, `decodeURI` or `unescape`.
    public static let uriDecoding = Features(rawValue: 1 << 13)
    /// A `<canvas>` element or a 2D context.
    public static let canvas = Features(rawValue: 1 << 14)
    /// Text drawn on a canvas (`fillText`, `strokeText`).
    public static let canvasText = Features(rawValue: 1 << 15)
    /// Inline `<svg>`.
    public static let svg = Features(rawValue: 1 << 16)
    /// Markup hidden statically (`hidden`, `display:none`, `visibility:hidden`,
    /// zero opacity or size) that contains text.
    public static let hiddenText = Features(rawValue: 1 << 17)
    /// A bot request (`TelegramWidget.request`).
    public static let requests = Features(rawValue: 1 << 18)
    /// A wallet call.
    public static let wallet = Features(rawValue: 1 << 19)
    /// The markup or a script could not be read completely (unterminated
    /// string, comment or tag, invalid escape).
    public static let malformed = Features(rawValue: 1 << 20)
  }
}
