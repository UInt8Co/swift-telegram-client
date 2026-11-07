#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import TelegramSchema
import TelegramRichText

@Suite struct InlineQuotationTests {
  @Test func quotationKeepsCJKAndWholeHashtags() {
    func quoted(_ text: String, limit: Int) -> String {
      RichMessage.plainText(InlineQuotation.clip(Text(text), limit: limit).richText)
    }
    #expect(quoted("这是一段没有空格的中文内容", limit: 6) == "这是一段没有…")
    #expect(quoted("這是一段沒有空格的中文內容", limit: 6) == "這是一段沒有…")
    #expect(quoted("中文#tag123456789", limit: 8) == "中文…")
    #expect(quoted("#tag123456789", limit: 8) == "…")
    #expect(quoted("one two three", limit: 6) == "one…")
    #expect(quoted("中文", limit: 0) == "…")
    #expect(quoted("中文", limit: -1) == "…")
  }
  @Test func quotationUsesCJKBoundariesAfterAnEarlySpace() {
    func quoted(_ text: String, _ limit: Int) -> String {
      RichMessage.plainText(InlineQuotation.clip(Text(text), limit: limit).richText)
    }
    #expect(quoted("ExampleApp 现已支持简体中文", 15) == "ExampleApp 现已支持…")
    #expect(quoted("ExampleApp 現已支援繁體中文", 15) == "ExampleApp 現已支援…")
    #expect(quoted("App 日本語のメッセージ", 7) == "App 日本語…")
    #expect(quoted("App 한국어메시지", 7) == "App 한국어…")
    #expect(quoted("App ，。！？更多", 8) == "App ，。！？…")
    #expect(quoted("App 中文 #tag123456789", 13) == "App 中文…")
    #expect(quoted("中文#tag123456789", 8) == "中文…")
    #expect(quoted("App #中文标签很长", 8) == "App…")
    #expect(quoted("one two three", 6) == "one…")
  }

  @Test func wordsAndReferenceMarkers() {
    let lead = Inline { Text(String(repeating: "word ", count: 30)); Hashtag("#item123456") }
    #expect(RichMessage.plainText(InlineQuotation.clip(lead, limit: 153).richText) == String(repeating: "word ", count: 30) + "…")
    #expect(RichMessage.plainText(InlineQuotation.clip(Text("alpha beta gamma"), limit: 13).richText) == "alpha beta…")
    #expect(RichMessage.plainText(InlineQuotation.clip(lead, limit: 200).richText) == String(repeating: "word ", count: 30) + "#item123456")
    let link = Text("Ada").link(to: "https://example.com").reference(Text("reference"), named: "person")
    #expect(RichMessage.plainText(InlineQuotation.clip(link, limit: 200).richText) == "Ada")
  }
}
