import TelegramSchema

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A received widget: its HTML, decoded from the media's payload, with its
/// current state and the flags the server set for this message.
public struct WidgetContent: Equatable, Sendable {
  public var html: String
  /// The shared state, seen in the original and every forward.
  public var publicData: String?
  /// The chat state, seen only in the original message's chat.
  public var chatData: String?
  /// The shared widget object this message shows, if it is one.
  public var widgetID: Int64?
  /// Size anchors in CSS pixels; 0 means automatic.
  public var width: Int32
  public var height: Int32
  /// The message is a forwarded copy.
  public var isCopy: Bool
  /// The widget may send requests to its bot on a tap.
  public var canQuery: Bool
  /// The widget may also send requests without a tap.
  public var backgroundQuery: Bool

  public init(
    html: String, publicData: String? = nil, chatData: String? = nil, widgetID: Int64? = nil,
    width: Int32 = 0, height: Int32 = 0, isCopy: Bool = false, canQuery: Bool = false,
    backgroundQuery: Bool = false
  ) {
    self.html = html
    self.publicData = publicData
    self.chatData = chatData
    self.widgetID = widgetID
    self.width = width
    self.height = height
    self.isCopy = isCopy
    self.canQuery = canQuery
    self.backgroundQuery = backgroundQuery
  }

  /// Decodes a received widget's payload.
  public init(_ media: TL.MessageMediaWidget) throws(WidgetPayload.DecodingError) {
    self.init(
      html: try WidgetPayload.html(fromPayload: media.payload), publicData: media.publicData,
      chatData: media.chatData, widgetID: media.widgetId, width: media.width, height: media.height,
      isCopy: media.isCopy, canQuery: media.canQuery, backgroundQuery: media.backgroundQuery)
  }

  /// Decodes an inline result's widget (a preview: no requests, no copy flag).
  public init(_ result: TL.BotInlineMessageWidget) throws(WidgetPayload.DecodingError) {
    self.init(
      html: try WidgetPayload.html(fromPayload: result.payload), publicData: result.publicData,
      chatData: result.chatData, widgetID: result.widgetId, width: result.width, height: result.height)
  }
}
