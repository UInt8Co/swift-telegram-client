import TelegramRichText
import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A native button embedded in a rich message's body.
public struct RichButton: Sendable {
  /// Telegram's mutually exclusive button appearances.
  public enum Style: Sendable, Equatable, CaseIterable {
    /// The default appearance.
    case plain
    /// The primary background.
    case primary
    /// The danger background.
    case danger
    /// The success background.
    case success
    /// A link appearance.
    case link

    fileprivate var value: TL.RichButtonStyle? {
      switch self {
      case .plain: nil
      case .primary: .init(bgPrimary: true)
      case .danger: .init(bgDanger: true)
      case .success: .init(bgSuccess: true)
      case .link: .init(link: true)
      }
    }
  }

  /// The native button, with a literal title and an input-compatible action.
  public let pageButton: TL.PageButton

  /// Whether a payload meets Telegram's inclusive 1–64 byte limit.
  public static func isValidCallbackData(_ data: Data) -> Bool { (1...64).contains(data.count) }

  /// Creates a callback button. `data` must contain 1–64 bytes; check dynamic
  /// payloads with `isValidCallbackData` before constructing the button.
  public static func callback(_ title: String, data: Data, style: Style = .plain) -> RichButton {
    precondition(isValidCallbackData(data), "Callback data must contain 1–64 bytes")
    return .init(
      pageButton: .init(
        text: Text(title).richText,
        type: .inlineButtonTypeCallback(.init(data: data)), style: style.value))
  }

  /// Creates a button that opens a URL.
  public static func url(_ title: String, _ url: String, style: Style = .plain) -> RichButton {
    .init(
      pageButton: .init(
        text: Text(title).richText,
        type: .inlineButtonTypeUrl(.init(url: url)), style: style.value))
  }

  /// Creates a button that copies literal text to the clipboard.
  public static func copy(_ title: String, text: String) -> RichButton {
    .init(
      pageButton: .init(
        text: Text(title).richText, type: .inlineButtonTypeCopy(.init(copyText: text))))
  }
}

/// A row of native buttons usable anywhere the rich-text DSL accepts a block.
public struct ButtonRow: BlockContent {
  /// The row's horizontal alignment.
  public enum Alignment: Sendable, Equatable, CaseIterable {
    /// Align buttons to the leading edge.
    case leading
    /// Center the buttons.
    case center
    /// Align buttons to the trailing edge.
    case trailing
    /// Shares the full row width between buttons, with no TL alignment flag.
    case stretched
  }

  private let alignment: Alignment
  private let buttons: [RichButton]

  /// Builds one row; an empty builder emits no block.
  public init(alignment: Alignment = .leading, @RichButtonBuilder _ buttons: () -> [RichButton]) {
    self.alignment = alignment
    self.buttons = buttons()
  }

  /// Input-compatible TL blocks. TelegramRichText already converts and
  /// validates text nested in `pageBlockButtonRow` and `textButton`.
  public var blocks: [TL.PageBlockType] {
    guard !buttons.isEmpty else { return [] }
    return [
      .pageBlockButtonRow(
        .init(
          alignLeft: alignment == .leading,
          alignCenter: alignment == .center, alignRight: alignment == .trailing,
          buttons: buttons.map(\.pageButton)))
    ]
  }
}

/// Composes buttons with conditionals, loops and arrays.
@resultBuilder
public enum RichButtonBuilder {
  /// Includes one button in the row.
  public static func buildExpression(_ button: RichButton) -> [RichButton] { [button] }
  /// Includes an array of buttons in order.
  public static func buildExpression(_ buttons: [RichButton]) -> [RichButton] { buttons }
  /// Concatenates builder components in source order.
  public static func buildBlock(_ parts: [RichButton]...) -> [RichButton] { parts.flatMap { $0 } }
  /// Includes an optional component when present.
  public static func buildOptional(_ part: [RichButton]?) -> [RichButton] { part ?? [] }
  /// Includes the first conditional branch.
  public static func buildEither(first: [RichButton]) -> [RichButton] { first }
  /// Includes the second conditional branch.
  public static func buildEither(second: [RichButton]) -> [RichButton] { second }
  /// Concatenates loop iterations in order.
  public static func buildArray(_ parts: [[RichButton]]) -> [RichButton] { parts.flatMap { $0 } }
  /// Includes a component guarded by an availability check.
  public static func buildLimitedAvailability(_ part: [RichButton]) -> [RichButton] { part }
}
