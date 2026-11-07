#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramArchive
import TelegramSchema
import Testing

@Suite struct ArchivePresentationTests {
  @Test func JSONCodeBlockIsIndentedWithoutChangingNumbersOrEscapedStrings() throws {
    let raw = #"{"id":9223372036854775807,"unsigned":18446744073709551615,"decimal":1.2300e+40,"nested":[{"text":"  ```\n\"quoted\" \\ {[,]} 🧪  ","empty":[]},true,false,null,{}]}"#
    let expected = #"""
    {
      "id": 9223372036854775807,
      "unsigned": 18446744073709551615,
      "decimal": 1.2300e+40,
      "nested": [
        {
          "text": "  ```\n\"quoted\" \\ {[,]} 🧪  ",
          "empty": []
        },
        true,
        false,
        null,
        {}
      ]
    }
    """#
    #expect(TLArchive.prettyPrintedJSON(raw) == expected)
    #expect(TLArchive.prettyPrintedJSON(expected) == expected)
  }
}
