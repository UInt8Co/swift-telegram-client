@testable import TelegramWidget
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// Header fixtures describe small images; a renderer is neither needed nor used.
private enum WidgetImageFixtures {
  static let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
    0, 0, 0, 7, 0, 0, 0, 9]
  static let gif: [UInt8] = Array("GIF89a".utf8) + [11, 0, 13, 0]
  static let jpeg: [UInt8] = [255, 216, 255, 224, 0, 4, 0, 0, 255, 194, 0, 8, 8, 0, 17, 0, 19, 0, 255, 217]
  static let webpX: [UInt8] = Array("RIFF".utf8) + [22, 0, 0, 0] + Array("WEBPVP8X".utf8)
    + [10, 0, 0, 0, 0, 0, 0, 0, 22, 0, 0, 28, 0, 0]
  static let webpL: [UInt8] = Array("RIFF".utf8) + [18, 0, 0, 0] + Array("WEBPVP8L".utf8)
    + [5, 0, 0, 0, 47, 30, 128, 8, 0, 0]
  static let webp: [UInt8] = Array("RIFF".utf8) + [22, 0, 0, 0] + Array("WEBPVP8 ".utf8)
    + [10, 0, 0, 0, 0, 0, 0, 157, 1, 42, 37, 0, 41, 0]

  static func url(_ bytes: [UInt8], type: String = "image/png") -> String {
    "data:\(type);base64,\(Data(bytes).base64EncodedString())"
  }
}

@Suite struct WidgetInspectionTests {
  @Test func joinsInlineTextAndSeparatesBlocks() {
    let result = WidgetInspection(html: "<p>t.me/<b>name</b></p><div>Hello <i>wide</i> world<br>next</div><ul><li>one<li>two</ul><table><tr><td>A</td><td>B</td></tr></table>")
    #expect(result.texts.map(\.value) == ["t.me/name", "Hello wide world", "next", "one", "two", "A", "B"])
  }

  @Test func decodesCharacterReferencesAndWhitespace() {
    let result = WidgetInspection(html: "<P> a\n\t b &amp; &lt; &gt; &quot; &apos; &nbsp; &#65; &#x1F642; &copy;&reg;&hellip;&mdash;&ndash;&laquo;&raquo;&euro; &unknown; &#0; </P>")
    #expect(result.texts.map(\.value) == ["a b & < > \" ' A 🙂 ©®…—–«»€ &unknown; �"])
  }

  @Test func readsAttributesInDocumentOrder() {
    let result = WidgetInspection(html: "<div title='first'><img ALT=second><input aria-label=third placeholder='fourth' value=fifth><button label=sixth>body</button></div>")
    #expect(result.texts.map(\.value) == ["first", "second", "third", "fourth", "fifth", "sixth", "body"])
    #expect(result.texts.map(\.origin) == [.attribute("title"), .attribute("alt"), .attribute("aria-label"),
      .attribute("placeholder"), .attribute("value"), .attribute("label"), .markup])
  }

  @Test func keepsBlockCandidateAtItsFirstTextPosition() {
    let result = WidgetInspection(html: "<p>A<span title='middle'>B</span>C</p>\n<img alt='later'> end")
    #expect(result.texts.map(\.value) == ["ABC", "middle", "later", "end"])
  }

  @Test func readsAnchorsAndDecodedTargets() {
    let result = WidgetInspection(html: "<a HREF='  https://example.test/?a=1&amp;b=2  '>Visit <b>here</b></a><a href=javascript:show()>Tap</a>")
    #expect(result.actions == [.init(kind: .anchor, target: "https://example.test/?a=1&b=2", label: "Visit here"),
      .init(kind: .anchor, target: "javascript:show()", label: "Tap")])
    #expect(result.features.contains(.script))
  }

  @Test func joinsAnchorBlocksWithSpaces() {
    let result = WidgetInspection(html: "<a href='/more'><div>One</div><div>Two</div></a>")
    #expect(result.actions.first?.label == "One Two")
  }

  @Test(arguments: ["hidden", "style='display:none'", "style='visibility: hidden'", "style='opacity:0'",
    "style='font-size:0px'", "style='width:0;height:2px;overflow:hidden'", "style='height:0px;overflow:hidden'"])
  func retainsHiddenText(_ attributes: String) {
    let result = WidgetInspection(html: "<div \(attributes)><b>Available</b></div>")
    #expect(result.texts == [.init("Available", origin: .markup)])
    #expect(result.features.contains(.hiddenText))
  }

  @Test func hiddenElementsWithoutTextDoNotSetHiddenText() {
    #expect(!WidgetInspection(html: "<div hidden><img src='x'></div>").features.contains(.hiddenText))
    #expect(!WidgetInspection(html: "<div style='opacity:.5;font-size:10px'>Shown</div>").features.contains(.hiddenText))
  }

  @Test func readsTemplateAndSkipsNoscript() {
    let result = WidgetInspection(html: "<!doctype html><!-- note --><template><div>Stored <em>markup</em></div></template><noscript><p>Fallback</p><script>ignored()</script></noscript>")
    #expect(result.texts == [.init("Stored markup", origin: .markup)])
    #expect(!result.features.contains(.script))
  }

  @Test func readsEscapableRawText() {
    let result = WidgetInspection(html: "<textarea placeholder='edit'>x <b>literal</b> &amp;</textarea><title>Title &copy;</title>")
    #expect(result.texts.map(\.value) == ["edit", "x <b>literal</b> &", "Title ©"])
  }

  @Test func readsSVGTextAndCanvasFeature() {
    let result = WidgetInspection(html: "<svg><text>North<tspan>bound</tspan></text></svg><canvas></canvas>")
    #expect(result.texts.map(\.value) == ["Northbound"])
    #expect(result.features.isSuperset(of: [.svg, .canvas]))
  }

  @Test func readsCSSStringsEscapesAndAttributeValues() {
    let result = WidgetInspection(html: #"<style>.x::before { content: "Go\20 " attr(data-name) "\1f642 "; } .x::after {content: counter(items) open-quote "!" close-quote} </style><div data-name="East">Map</div><div data-name="West"></div>"#)
    #expect(result.texts == [.init("Go East🙂", origin: .styleContent), .init("Go West🙂", origin: .styleContent),
      .init("!", origin: .styleContent), .init("Map", origin: .markup)])
  }

  @Test func resolvesInlineCSSAgainstOwnAttributes() {
    let result = WidgetInspection(html: #"<div data-label="Near" style="content: '\4e ' attr(data-label)">View</div><div data-label="Far"></div>"#)
    #expect(result.texts.map(\.value) == ["NNear", "View"])
    #expect(result.texts.first?.origin == .styleContent)
  }

  @Test func CSSCommentsAndStringsDoNotCreateFeatures() {
    let result = WidgetInspection(html: #"<style>/* transition: all 1s; content: "ignored" */ a { content: "animation: none"; }</style>"#)
    #expect(result.texts.map(\.value) == ["animation: none"])
    #expect(!result.features.contains(.styleAnimation))
  }

  @Test func detectsCSSMotion() {
    for style in ["a{transition:opacity 1s}", "a{animation-name:slide}", "@keyframes slide {from{opacity:0}to{opacity:1}}"] {
      #expect(WidgetInspection(html: "<style>\(style)</style>").features.contains(.styleAnimation))
    }
  }

  @Test func readsNonJavaScriptBlocksAfterMarkupAsLiterals() {
    let result = WidgetInspection(html: #"<script type="application/json">{"key":"String", "array":[12,"Leaf"]}</script><p>First</p><script type="text/template"><b>Template</b></script>"#)
    #expect(result.texts == [.init("First", origin: .markup), .init("String", origin: .scriptLiteral),
      .init("Leaf", origin: .scriptLiteral), .init("<b>Template</b>", origin: .scriptLiteral)])
  }

  @Test func delegatesAllJavaScriptTypesAndHandlers() {
    for type in ["", "module", "text/javascript", "application/javascript", "TEXT/ECMASCRIPT"] {
      let result = WidgetInspection(html: "<script type='\(type)'>show('x < y');</script><button onclick='show()'>Tap</button>")
      #expect(result.features.contains(.script))
      #expect(result.texts.contains(.init("Tap", origin: .markup)))
      #expect(!result.texts.contains(.init("show('x < y');", origin: .markup)))
    }
  }

  @Test func readsImageSignaturesAndDimensions() {
    let cases: [([UInt8], WidgetInspection.Image.Format, Int, Int)] = [
      (WidgetImageFixtures.png, .png, 7, 9), (WidgetImageFixtures.gif, .gif, 11, 13),
      (WidgetImageFixtures.jpeg, .jpeg, 19, 17), (WidgetImageFixtures.webpX, .webp, 23, 29),
      (WidgetImageFixtures.webpL, .webp, 31, 35), (WidgetImageFixtures.webp, .webp, 37, 41),
    ]
    for (bytes, format, width, height) in cases {
      let result = WidgetInspection(html: "<img src='\(WidgetImageFixtures.url(bytes, type: "text/plain"))'>")
      #expect(result.images == [.init(format: format, declaredMediaType: "text/plain", width: width, height: height, data: bytes)])
    }
  }

  @Test func readsPercentDataAndUnknownAndSVG() {
    let result = WidgetInspection(html: "<img src='data:image/svg+xml,%3Csvg%20xmlns=%22x%22%3E%3C/svg%3E'><img src='data:application/octet-stream,%00%01%FF'>")
    #expect(result.images.map(\.format) == [.svg, .unknown])
    #expect(result.images.first?.width == nil)
    #expect(result.images.last?.data == [0, 1, 255])
  }

  @Test func readsAllMarkupImageSources() {
    let url = WidgetImageFixtures.url(WidgetImageFixtures.gif)
    let result = WidgetInspection(html: "<img srcset='\(url) 1x, \(url) 2x'><source srcset='\(url) 3x'><svg><image xlink:href='\(url)'/><image href='\(url)'/></svg>")
    #expect(result.images.count == 5)
    #expect(result.images.allSatisfy { $0.format == .gif })
  }

  @Test func readsCSSDataURLs() {
    let url = WidgetImageFixtures.url(WidgetImageFixtures.png)
    let result = WidgetInspection(html: "<style>.x { background:url('\(url)') }</style><div style='background-image:url(\(url))'></div>")
    #expect(result.images.count == 2)
  }

  @Test func capsImageCountAndAggregateBytes() {
    let url = WidgetImageFixtures.url(WidgetImageFixtures.gif)
    let html = "<img src='\(url)'><img src='\(url)'>"
    let count = WidgetInspection(html: html, limits: .init(maximumImages: 1))
    #expect(count.images.count == 1)
    #expect(count.isTruncated)
    let bytes = WidgetInspection(html: html, limits: .init(maximumImageBytes: WidgetImageFixtures.gif.count))
    #expect(bytes.images.count == 1)
    #expect(bytes.isTruncated)
    let none = WidgetInspection(html: html, limits: .init(maximumImageBytes: 1))
    #expect(none.images.isEmpty)
    #expect(none.isTruncated)
  }

  @Test func handlesTruncatedHeadersAndInvalidDataURLs() {
    for bytes in [[UInt8]([255, 216, 255, 224, 255, 255]), Array("RIFFxxxxWEBP".utf8), Array(WidgetImageFixtures.png.prefix(8))] {
      let result = WidgetInspection(html: "<img src='\(WidgetImageFixtures.url(bytes))'>")
      #expect(result.images.count == 1)
      #expect(result.images.first?.width == nil)
    }
    #expect(WidgetInspection(html: "<img src='data:image/png;base64,!!!'>").images.isEmpty)
  }

  @Test func readsJSONLeavesWithPaths() {
    let result = WidgetInspection(html: "", publicData: #"{"items":[false,2,{"title":"Third", "other":["Nested"]}],"name":"Guide","empty":null}"#,
      chatData: #""Top level""#)
    #expect(result.texts == [.init("Third", origin: .state(.publicData, path: "items[2].title")),
      .init("Nested", origin: .state(.publicData, path: "items[2].other[0]")),
      .init("Guide", origin: .state(.publicData, path: "name")), .init("Top level", origin: .state(.chatData, path: ""))])
  }

  @Test func decodesJSONEscapesAndSurrogatePairs() {
    let result = WidgetInspection(html: "", publicData: #"["\uD83D\uDE42", "line\nnext", "quote\"slash\\"]"#)
    #expect(result.texts.map(\.value) == ["🙂", "line\nnext", "quote\"slash\\"])
  }

  @Test func retainsPlainStateAndRejectsIncompleteJSON() {
    for source in ["Plain text", #"{"bad": "unfinished""#, "[01]", #""\uD800""#] {
      let result = WidgetInspection(html: "", publicData: source)
      #expect(result.texts == [.init(source, origin: .state(.publicData, path: nil))])
    }
    #expect(WidgetInspection(html: "", publicData: "[true,2,null]").texts.isEmpty)
  }

  @Test func boundsJSONDepth() {
    let source = String(repeating: "[", count: 100) + "\"deep\"" + String(repeating: "]", count: 100)
    let result = WidgetInspection(html: "", publicData: source)
    #expect(result.isTruncated)
    #expect(result.texts.first?.origin == .state(.publicData, path: nil))
  }

  @Test func ordersAndDeduplicatesByValueAndOrigin() {
    let result = WidgetInspection(html: #"<script type="application/json">["same","same","last"]</script><p title="same">same</p><p>same</p>"#,
      publicData: #"["same","same"]"#)
    #expect(result.texts == [.init("same", origin: .attribute("title")), .init("same", origin: .markup),
      .init("same", origin: .scriptLiteral), .init("last", origin: .scriptLiteral),
      .init("same", origin: .state(.publicData, path: "[0]")), .init("same", origin: .state(.publicData, path: "[1]"))])
  }

  @Test func enforcesTextAndActionCounts() {
    let result = WidgetInspection(html: "<p>One</p><p>Two</p><a href=a>A</a><a href=b>B</a>",
      limits: .init(maximumTexts: 2, maximumActions: 1))
    #expect(result.texts.map(\.value) == ["One", "Two"])
    #expect(result.actions == [.init(kind: .anchor, target: "a", label: "A")])
    #expect(result.isTruncated)
  }

  @Test func cutsTextAtCharacterBoundariesAndCapsTotalBytes() {
    let result = WidgetInspection(html: "<p>A🙂B</p><p>ééé</p><p>tail</p>",
      limits: .init(maximumTextBytes: 5, maximumTotalTextBytes: 8))
    #expect(result.texts.map(\.value) == ["A🙂", "é", "t"])
    #expect(result.texts.reduce(0) { $0 + $1.value.utf8.count } == 8)
    #expect(result.isTruncated)
    let cluster = WidgetInspection(html: "e\u{301}", limits: .init(maximumTextBytes: 2))
    #expect(cluster.texts.isEmpty)
    #expect(cluster.isTruncated)
  }

  @Test func toleratesNegativeAndZeroLimits() {
    let result = WidgetInspection(html: "<a href=x>X</a><img src='data:,x'>", publicData: #"["Y"]"#,
      limits: .init(maximumTexts: -1, maximumTextBytes: -1, maximumTotalTextBytes: -1,
        maximumActions: -1, maximumImages: -1, maximumImageBytes: -1, maximumNesting: -1))
    #expect(result.texts.isEmpty && result.actions.isEmpty && result.images.isEmpty)
    #expect(result.isTruncated)
  }

  @Test func doesNotReportTruncationForDuplicatesOrEmptyText() {
    let result = WidgetInspection(html: "<p>same</p><p>same</p><div> \n </div>", limits: .init(maximumTexts: 1))
    #expect(result.texts.count == 1)
    #expect(!result.isTruncated)
  }

  @Test(arguments: ["<!-- unfinished", "<div", "<p title='unfinished", "<p title=", "hello < world", "<", "<style>/* unfinished</style>"])
  func marksMalformedInputAndFinishes(_ html: String) {
    #expect(WidgetInspection(html: html).features.contains(.malformed))
  }

  @Test func handlesVoidElementsCaseAndUnclosedBlocks() {
    let result = WidgetInspection(html: "<DIV>one<IMG alt=picture><BR/>two</DIV><p>last")
    #expect(result.texts.map(\.value) == ["one", "picture", "two", "last"])
  }

  @Test func mergesScriptFragmentsWithSinkOrigins() {
    var inspector = WidgetInspector(limits: .init())
    var analysis = WidgetScriptAnalysis()
    analysis.texts = [.init("Direct", origin: .script(.textContent))]
    analysis.htmlFragments = [.init(html: #"<p title="Hint">Written <b>text</b></p><a href="/next">Next</a><button onclick="tap()">Tap</button><script>inert()</script>"#, sink: .innerHTML)]
    analysis.dataURLs = [WidgetImageFixtures.url(WidgetImageFixtures.gif)]
    analysis.actions = [.init(kind: .openLink, target: "/direct")]
    analysis.features = [.readsState]
    inspector.merge(analysis, nesting: 0)
    #expect(inspector.result.texts == [.init("Direct", origin: .script(.textContent)),
      .init("Hint", origin: .script(.innerHTML)), .init("Written text", origin: .script(.innerHTML)),
      .init("NextTap", origin: .script(.innerHTML)), .init("inert()", origin: .scriptLiteral)])
    #expect(inspector.result.actions == [.init(kind: .openLink, target: "/direct"),
      .init(kind: .anchor, target: "/next", label: "Next")])
    #expect(inspector.result.features.isSuperset(of: [.readsState, .script]))
    #expect(inspector.result.images.count == 1)
  }

  @Test func capsFragmentNestingAndPropagatesTruncation() {
    var inspector = WidgetInspector(limits: .init(maximumNesting: 0))
    var analysis = WidgetScriptAnalysis()
    analysis.htmlFragments = [.init(html: "<p>deeper</p>", sink: .innerHTML)]
    inspector.merge(analysis, nesting: 0)
    #expect(inspector.result.texts.isEmpty)
    #expect(inspector.result.isTruncated)
    var other = WidgetInspector(limits: .init())
    analysis.htmlFragments = []
    analysis.isTruncated = true
    other.merge(analysis, nesting: 0)
    #expect(other.result.isTruncated)
  }


  @Test func appliesLimitsAfterJSONAndCSSDeduplication() {
    let script = WidgetInspection(html: #"<script type="application/json">["same","same"]</script>"#,
      limits: .init(maximumTexts: 1))
    #expect(script.texts == [.init("same", origin: .scriptLiteral)])
    #expect(!script.isTruncated)
    let state = WidgetInspection(html: "", publicData: #"{"key":"same","key":"same"}"#,
      limits: .init(maximumTexts: 1))
    #expect(state.texts == [.init("same", origin: .state(.publicData, path: "key"))])
    #expect(!state.isTruncated)
    let css = WidgetInspection(html: #"<style>a::before {content:attr(data-label)}</style><i data-label="A"></i><i data-label="A"></i><i data-label="B"></i>"#,
      limits: .init(maximumTexts: 2))
    #expect(css.texts.map(\.value) == ["A", "B"])
    #expect(!css.isTruncated)
  }

  @Test func givesAllFragmentDisplayCandidatesTheSinkOrigin() {
    var inspector = WidgetInspector(limits: .init())
    var analysis = WidgetScriptAnalysis()
    analysis.htmlFragments = [.init(html: "<p style=\"content:'CSS'\">Body<img alt='Picture' src='\(WidgetImageFixtures.url(WidgetImageFixtures.png))'></p>", sink: .documentWrite)]
    inspector.merge(analysis, nesting: 0)
    #expect(inspector.result.texts.map(\.value) == ["CSS", "Body", "Picture"])
    #expect(inspector.result.texts.allSatisfy { $0.origin == .script(.documentWrite) })
    #expect(inspector.result.images.first?.format == .png)
  }

  @Test func repeatedFragmentHandlersRemainNestingBounded() {
    var inspector = WidgetInspector(limits: .init(maximumNesting: 1))
    var analysis = WidgetScriptAnalysis()
    analysis.htmlFragments = [.init(html: "<p>first</p>", sink: .innerHTML)]
    inspector.merge(analysis, nesting: 0)
    inspector.merge(analysis, nesting: 1)
    #expect(inspector.result.texts == [.init("first", origin: .script(.innerHTML))])
    #expect(inspector.result.isTruncated)
  }

  @Test func deterministicMalformedInputsAlwaysFinish() {
    let alphabet = Array("<>=/'\"!-&; ab\n012".unicodeScalars)
    var seed: UInt64 = 91
    for _ in 0..<512 {
      var source = ""
      for _ in 0..<80 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        source.unicodeScalars.append(alphabet[Int(seed >> 32) % alphabet.count])
      }
      let result = WidgetInspection(html: source, limits: .init(maximumTexts: 4, maximumTextBytes: 16,
        maximumTotalTextBytes: 32, maximumActions: 2, maximumImages: 1))
      #expect(result.texts.count <= 4)
      #expect(result.texts.reduce(0) { $0 + $1.value.utf8.count } <= 32)
      #expect(result.actions.count <= 2)
    }
  }

  @Test func realisticSmallWidget() {
    let html = #"""
      <!doctype html><style>.badge::before{content:"Route " attr(data-route)} .pulse{animation:glow 2s}</style>
      <main><h2 title="Journey planner">Today’s <span>trips</span></h2><div class="badge" data-route="7">Northbound</div>
      <template><p>Choose a stop</p></template><p hidden>Schedule updates</p>
      <a href="https://example.test/times?route=7&amp;day=today">View <b>times</b></a>
      <svg><text>Map</text></svg><canvas></canvas><button onclick="refresh()">Refresh</button></main>
      <script type="application/json">{"caption":"Service information","count":2}</script>
      """#
    let result = WidgetInspection(html: html, publicData: #"{"stops":[{"name":"Central"}]}"#, chatData: "Selected: Central")
    #expect(result.texts.contains(.init("Route 7", origin: .styleContent)))
    #expect(result.texts.contains(.init("Today’s trips", origin: .markup)))
    #expect(result.texts.suffix(3) == [.init("Service information", origin: .scriptLiteral),
      .init("Central", origin: .state(.publicData, path: "stops[0].name")),
      .init("Selected: Central", origin: .state(.chatData, path: nil))])
    #expect(result.actions.first?.label == "View times")
    #expect(result.features.isSuperset(of: [.styleAnimation, .hiddenText, .svg, .canvas, .script]))
    #expect(!result.isTruncated)
  }
}
