@testable import TelegramWidget
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct WidgetAuditRegressionTests {
  private func inspect(_ script: String, limits: WidgetInspection.Limits = .init()) -> WidgetInspection {
    WidgetInspection(html: "<script>\(script)</script>", limits: limits)
  }

  private func shown(_ result: WidgetInspection, _ value: String) -> Bool {
    result.texts.contains { $0.origin.isShown && $0.value == value }
  }

  private func caps(_ result: WidgetInspection, _ limits: WidgetInspection.Limits = .init()) {
    #expect(result.texts.count <= max(0, limits.maximumTexts))
    #expect(result.texts.allSatisfy { $0.value.utf8.count <= max(0, limits.maximumTextBytes) })
    #expect(result.texts.reduce(0) { $0 + $1.value.utf8.count } <= max(0, limits.maximumTotalTextBytes))
    #expect(result.actions.count <= max(0, limits.maximumActions))
    #expect(result.images.count <= max(0, limits.maximumImages))
    #expect(result.images.reduce(0) { $0 + $1.data.count } <= max(0, limits.maximumImageBytes))
    #expect(result.texts.allSatisfy { !$0.value.contains(WidgetReading.hole) })
    #expect(result.actions.allSatisfy {
      !($0.target ?? "").contains(WidgetReading.hole) && !($0.label ?? "").contains(WidgetReading.hole)
    })
  }

  @Test func boundsConstructedDepthAndCachedComposites() {
    let source = "<script>x.textContent=[0]" + String(repeating: ".map(x=>[x])", count: 2_500) + ";</script>"
    #expect(source.utf8.count == 30_035)
    let result = WidgetInspection(html: source)
    #expect(result.isTruncated)
    caps(result)
    var mixed = "const a0=[0];"
    for i in 1...180 { mixed += "const a\(i)=[{v:a\(i - 1)}];" }
    mixed += "x.textContent=a180;"
    let cached = inspect(mixed)
    #expect(cached.isTruncated)
    #expect(cached.features.contains(.unresolvedOutput))
    caps(cached)
    let reference = inspect("document" + String(repeating: ".x", count: 16_000))
    #expect(reference.isTruncated)
    caps(reference)
  }

  @Test func boundsCSSExpansionAndUsesOneElement() {
    let source = "<style>i:before{content:" + String(repeating: "attr(x)", count: 500) + "}</style>"
      + (0..<1_024).map { "<i x=\(String(repeating: "0", count: 4 - String($0).count))\($0)></i>" }.joined()
    #expect(source.utf8.count == 17_869)
    for limits in [WidgetInspection.Limits(), .init(maximumTexts: 0)] {
      let result = WidgetInspection(html: source, limits: limits)
      #expect(result.isTruncated)
      caps(result, limits)
    }
    let result = WidgetInspection(html: #"<style>i:before{content:attr(x) ':' attr(y)}</style><i x=A y=1></i><i x=B y=2></i>"#)
    #expect(result.texts.map(\.value) == ["A:1", "B:2"])
    var budget = WidgetMarkupBudget()
    let css = WidgetCSSReader(String(repeating: "content:attr(x);", count: 1_000),
      attributes: (0..<1_024).map { ["x": String($0)] }, limits: .init(), budget: &budget)
    #expect(css.isTruncated)
    #expect(budget.remaining >= 0)
    #expect(css.texts.count <= 1_024)
  }

  @Test func boundsMapAndCompositeAllocation() {
    for expression in [
      "'x'.repeat(4096).split('').map(x=>'y'.repeat(16384))",
      "['y'.repeat(16384),'z'.repeat(16384)]",
      "({a:'y'.repeat(16384),b:'z'.repeat(16384)})",
      "['y'.repeat(16384)].concat(['z'.repeat(16384)])",
      "[...['y'.repeat(16384)],...['z'.repeat(16384)]]",
    ] {
      let result = inspect("x.textContent=\(expression)")
      #expect(result.isTruncated)
      #expect(result.features.contains(.unresolvedOutput))
      caps(result)
    }
  }

  @Test func handlesLargeAttributesAndUnmatchedClosingTags() {
    let attributes = (0..<4_096).map { " a\($0)=x" }.joined()
    let tag = WidgetInspection(html: "<p\(attributes) title='kept'>body</p>")
    #expect(shown(tag, "kept"))
    #expect(shown(tag, "body"))
    let source = String(repeating: "<a>", count: 4_096) + String(repeating: "</b>", count: 4_096)
    #expect(source.utf8.count == 28_672)
    let result = WidgetInspection(html: source)
    #expect(result.features.contains(.malformed))
    caps(result)
    let fragments = inspect("x.innerHTML='" + String(repeating: "<a>", count: 2_000) + "';"
      + String(repeating: "x.innerHTML='<p>fragment</p>';", count: 100))
    caps(fragments)
    let repeated = "const fragment='<p>" + String(repeating: "x", count: 512) + "</p>';"
      + String(repeating: "x.innerHTML=fragment;", count: 800)
    var scriptBudget = WidgetScriptBudget(limits: .init())
    let analysis = WidgetScriptAnalysis.analyze(repeated, isHandler: false, budget: &scriptBudget, limits: .init())
    #expect(!analysis.isTruncated)
    let shared = inspect(repeated)
    #expect(shared.isTruncated)
    #expect(shared.texts.count == 1)
    caps(shared)
  }

  @Test func preservesOnlyOutputContributions() {
    for expression in [
      "lookup('internal-key')", "('internal-key'===runtime)",
      "runtime['internal-key']", "querySelector('internal-key')",
      "unknown({ 'internal-key': runtime })", "unknown(`internal-key${runtime}`)",
    ] {
      let result = inspect("x.textContent=\(expression)")
      #expect(!shown(result, "internal-key"))
      #expect(result.texts.contains(.init("internal-key", origin: .scriptLiteral)))
      #expect(result.features.contains(.unresolvedOutput))
    }
    let result = inspect(#"x.textContent=lookup('key')+'suffix'; x.innerText=flag?'yes':'no'; x.value=runtime??'fallback';"#)
    for value in ["suffix", "yes", "no", "fallback"] { #expect(shown(result, value)) }
    #expect(!shown(result, "key"))
    for expression in [
      "`shown${unknown('key')}`", "['shown',runtime].join('|')", "runtime.concat('shown')",
      "items.map(x=>'shown'+unknown('key')).join('')", "('shown'+runtime).trim()",
      "('shown'+runtime).toUpperCase()", "('shown'+runtime).toLowerCase()",
      "('shown'+runtime).repeat(2)", "runtime.padStart(8,'shown')", "runtime.padEnd(8,'shown')",
    ] {
      let result = inspect("x.textContent=\(expression)")
      #expect(shown(result, expression.contains("toUpperCase") ? "SHOWN" : "shown"))
      #expect(!shown(result, "key"))
    }
    #expect(!shown(inspect("Array.prototype.join=custom;x.textContent=['candidate',runtime].join('')"), "candidate"))
    #expect(!shown(inspect("String.prototype.toUpperCase=custom;x.textContent=('candidate'+runtime).toUpperCase()"), "CANDIDATE"))
    #expect(!shown(inspect("x.textContent=1+runtime"), "1"))
    #expect(!shown(inspect("x.textContent=[null,runtime].join('')"), "null"))
    #expect(!shown(inspect("x.textContent=items.map(x=>null).join('')"), "null"))
    let condition = inspect(#"x.textContent=('condition'===runtime)?'yes':'no'"#)
    #expect(condition.texts.contains(.init("condition", origin: .scriptLiteral)))
  }

  @Test func preservesUnknownHTMLHoles() {
    let result = inspect(#"x.innerHTML='<a href="https://'+runtime+'.example/">Go</a>'"#)
    #expect(result.actions == [.init(kind: .anchor, target: nil, label: "Go")])
    #expect(result.features.isSuperset(of: [.unresolvedOutput, .unresolvedAction]))
    for expression in [
      #"'left'+runtime+'right'"#,
      #"'<a'+runtime+' href="https://example.test/">Go</a>'"#,
      #"'<a href='+runtime+'"https://example.test/">Go</a>'"#,
      #"'&am'+runtime+'p;'"#,
      #"'&#1'+runtime+'28;'"#,
      #"'&#128'+runtime+';'"#,
      #"'<img src="data:image/png;base64,'+runtime+'AQ==" alt="a'+runtime+'b">'"#,
      #"'<p title="left'+runtime+'right">body</p>'"#,
    ] {
      let reading = inspect("x.innerHTML=\(expression)")
      caps(reading)
      #expect(!shown(reading, "leftright"))
      #expect(!shown(reading, "&"))
      #expect(!shown(reading, "€"))
      #expect(reading.images.isEmpty)
      #expect(reading.actions.allSatisfy { $0.target == nil })
    }
    let split = inspect(#"x.innerHTML='left'+runtime+'right'"#)
    #expect(split.texts.filter(\.origin.isShown).map(\.value) == ["left", "right"])
    let joined = inspect(#"x.innerHTML=['<b>A</b>',runtime,'<i>B</i>'].join(' / ')"#)
    #expect(!shown(joined, "AB /"))
    caps(joined)
  }

  @Test func ordersAllScriptEventsBeforeApplyingLimits() {
    let source = #"x.innerHTML='<b>first</b>'; x.textContent='second'; 'third'; eval("x.innerHTML='<i>fourth</i>';x.innerText='fifth'"); x.textContent='sixth';"#
    let result = inspect(source)
    #expect(result.texts.map(\.value) == ["first", "second", "third", "fourth", "fifth", "sixth"])
    let limited = inspect(source, limits: .init(maximumTexts: 1))
    #expect(limited.texts.map(\.value) == ["first"])
    #expect(limited.isTruncated)
    let bytes = inspect(source, limits: .init(maximumTotalTextBytes: 7))
    #expect(bytes.texts.map(\.value) == ["first", "se"])
    let emptyFragment = inspect("x.innerHTML='<br>';x.innerHTML='<b>first</b>'", limits: .init(maximumTexts: 1))
    #expect(emptyFragment.texts.map(\.value) == ["first"])
    let actionsOnly = inspect(#"x.innerHTML='<a href="/first">first</a>'"#, limits: .init(maximumTexts: 0))
    #expect(actionsOnly.actions.first?.target == "/first")
    let actions = inspect(#"x.innerHTML='<a href="/first">first</a>';TelegramWidget.openLink('/second');"#)
    #expect(actions.actions.map(\.target) == ["/first", "/second"])
  }

  @Test func sharesDecodingDepthThroughOperationsAndFragments() {
    for limit in [0, 1, 3] {
      for expression in ["atob(atob('UVE9PQ=='))", "decodeURIComponent(atob('JTQx'))", "atob(decodeURIComponent('QQ%3D%3D'))"] {
        let result = inspect("x.textContent=\(expression)", limits: .init(maximumNesting: limit))
        #expect(shown(result, "A") == (limit >= 2))
        #expect(result.isTruncated == (limit < 2))
      }
    }
    let source = #"eval("x.innerHTML=\"<button onclick='eval(&quot;x.textContent=&#39;deep&#39;&quot;)'>Tap</button>\"")"#
    for limit in [0, 1, 2, 3] {
      let result = inspect(source, limits: .init(maximumNesting: limit))
      #expect(shown(result, "deep") == (limit >= 3))
      #expect(result.isTruncated == (limit < 3))
    }
    for limit in [1, 2] {
      let partial = inspect("x.innerHTML=runtime+atob('PGI+QTwvYj4=')", limits: .init(maximumNesting: limit))
      #expect(shown(partial, "A") == (limit == 2))
      #expect(partial.isTruncated == (limit == 1))
    }
    let mapped = inspect("x.textContent=atob('UVE9PQ==').split(' ').map(x=>atob(x)).join('')", limits: .init(maximumNesting: 1))
    #expect(!shown(mapped, "A"))
    #expect(mapped.isTruncated)
    let cached = inspect("const a=atob('UVE9PQ=='); const b=atob(a); x.textContent=b;", limits: .init(maximumNesting: 1))
    #expect(!shown(cached, "A"))
    #expect(cached.isTruncated)
  }

  @Test func ignoresBytesAfterFirstCompletePayloadStream() throws {
    let stream = WidgetPayloadFixtures.html
    for suffix in [[0], [1, 2, 255], stream] {
      #expect(try WidgetPayload.html(fromPayload: Data(stream + suffix)) == "<p>Hello, widget!</p>")
    }
    let empty: [UInt8] = [120, 156, 3, 0, 0, 0, 0, 1]
    #expect(try WidgetPayload.html(fromPayload: Data(empty + [255])) == "")
  }

  @Test func invalidatesComputedMutationsAndNestedAliases() {
    for source in [
      "const a=['first','last']; a['reverse'](); x.textContent=a[0]",
      "const a=['first']; a['push']('last'); x.textContent=a[0]",
      "const a=['first']; a['splice'](0,1); x.textContent=a[0]",
      "const a=['first']; const method='reverse'; a[method](); x.textContent=a[0]",
      "const a={b:['old']}; const b=a.b; b[0]='new'; x.textContent=a.b[0]",
      "const a={b:{c:['old']}}; const {c}=a.b; c[0]='new'; x.textContent=a.b.c[0]",
      "const a={b:[['old']]}; const [b]=a.b; b[0]='new'; x.textContent=a.b[0][0]",
    ] {
      let result = inspect(source)
      #expect(result.features.contains(.unresolvedOutput))
      #expect(!shown(result, "first"))
      #expect(!shown(result, "old"))
    }
  }

  @Test func retainsCodeAfterExpressionBodiesAndRegex() {
    for prefix in [
      "const f=function(){} / 2;", "const f=function named(){} / 2;", "const f=async function(){} / 2;",
      "const f=typeof function(){} / 2;", "const f=flag&&function(){} / 2;",
      "const f=()=>{} / 2;", "const f=class {} / 2;", "const f=class Named {} / 2;",
      "const f={a:1} / 2;", "if(flag){} /'ignored'/.test(x);",
      "function f(){} /'ignored'/.test(x);", "class F {} /'ignored'/.test(x);",
    ] {
      let result = inspect(prefix + "x.textContent='visible';")
      #expect(shown(result, "visible"))
      #expect(!result.texts.contains { $0.value == "ignored" })
      #expect(!result.features.contains(.malformed))
    }
  }

  @Test func truncatesScriptAtEveryGraphemeBoundary() {
    for cluster in ["e\u{301}", "✈️", "🇬🇧", "👩‍💻"] {
      for cut in 0...cluster.utf8.count {
        let limits = WidgetInspection.Limits(maximumTextBytes: cut)
        let result = inspect("x.textContent='\(cluster)'", limits: limits)
        #expect(result.texts.map(\.value) == (cut == cluster.utf8.count ? [cluster] : []))
        #expect(result.isTruncated == (cut < cluster.utf8.count))
        caps(result, limits)
      }
    }
  }

  @Test func distinguishesJSONPathsAndEscapesKeys() {
    let result = WidgetInspection(html: "", publicData: #"{"a.b":"same","a":{"b":"same"},"items[0]":"other","items":["other"],"":"empty","q\"\\":"escaped","\n":"line"}"#)
    let paths = result.texts.compactMap { text -> String? in
      if case .state(_, let path) = text.origin { return path }
      return nil
    }
    #expect(paths == [#"["a.b"]"#, "a.b", #"["items[0]"]"#, "items[0]", #"[""]"#, #"["q\"\\"]"#, #"["\n"]"#])
    #expect(result.texts.count == 7)
  }

  @Test func decodesLegacyReferencesAndCSSEscapes() {
    let result = WidgetInspection(html: "<p>&#128; &#x92; &#0; &#xD800; &#999999999999999999999;</p>"
      + "<style>i{content:'\\000041\r\nB'}</style>")
    #expect(result.texts.map(\.value) == ["€ ’ � � �", "AB"])
    let controls = WidgetInspection(html: (128...159).map { "&#\($0);" }.joined())
    #expect(controls.texts.first?.value.hasPrefix("€\u{81}‚ƒ„…†‡") == true)
  }

  @Test func pinsExactBudgetBoundariesAndDeduplication() {
    let source = "x.textContent='hello'"
    var lexer = WidgetScriptLexer(source, tokens: 100)
    let tokenCount = lexer.read().tokens.count
    #expect(!inspect(source, limits: .init(maximumScriptTokens: tokenCount)).isTruncated)
    #expect(inspect(source, limits: .init(maximumScriptTokens: tokenCount - 1)).isTruncated)
    let scripts = WidgetInspection(html: "<script>\(source)</script><script>x.innerText='later'</script>",
      limits: .init(maximumScriptTokens: tokenCount))
    #expect(shown(scripts, "hello"))
    #expect(!shown(scripts, "later"))
    #expect(scripts.isTruncated)
    var work = WidgetScriptBudget(limits: .init())
    _ = WidgetScriptAnalysis.analyze(source, isHandler: false, budget: &work, limits: .init())
    let used = 50_000 - work.foldingSteps
    #expect(!inspect(source, limits: .init(maximumFoldingSteps: used)).isTruncated)
    #expect(inspect(source, limits: .init(maximumFoldingSteps: used - 1)).isTruncated)
    for size in [4, 5] {
      let result = inspect(source, limits: .init(maximumTextBytes: size, maximumTotalTextBytes: size))
      #expect(result.texts.first?.value == String("hello".prefix(size)))
      #expect(result.isTruncated == (size < 5))
      let image = WidgetInspection(html: "<img src='data:application/octet-stream,hello'>", limits: .init(maximumImageBytes: size))
      #expect(image.images.count == (size == 5 ? 1 : 0))
      #expect(image.isTruncated == (size < 5))
    }
    let duplicate = inspect("x.textContent='same';x.textContent='same';", limits: .init(maximumTexts: 1, maximumTotalTextBytes: 4))
    #expect(duplicate.texts.count == 1)
    #expect(!duplicate.isTruncated)
    let cut = inspect("x.textContent='sameA';x.textContent='sameB';", limits: .init(maximumTextBytes: 4))
    #expect(cut.texts.map(\.value) == ["same"])
    #expect(cut.isTruncated)
  }

  @Test func handlesDeepAndMalformedDocuments() {
    let deep = [
      String(repeating: "(", count: 32_768), String(repeating: "!", count: 32_768),
      String(repeating: "[", count: 32_768), String(repeating: "{a:", count: 10_922) + "{}",
      String(repeating: "`a${", count: 8_192),
    ]
    for source in deep {
      let result = inspect(source)
      #expect(result.isTruncated)
      caps(result)
    }
    for source in ["/'", "'", "/*"] {
      let result = inspect(source + String(repeating: "x", count: 32_768))
      #expect(result.features.contains(.malformed))
      caps(result)
    }
    let tag = WidgetInspection(html: "<p title='" + String(repeating: "x", count: 32_768))
    #expect(tag.features.contains(.malformed))
    caps(tag)
    let state = String(repeating: "[", count: 511) + "[]" + String(repeating: "]", count: 511)
    #expect(state.utf8.count == 1_024)
    let result = WidgetInspection(html: "", publicData: state)
    #expect(result.isTruncated)
    caps(result)
  }

  @Test func deterministicDocumentMutationsRespectEveryCap() {
    // Original documents; mutations are inspected as data, never executed.
    let documents = [
      #"<style>i:before{content:attr(data-label) '!'}</style><i data-label='Stop'>Central</i><script>x.textContent=['Next',state.name].join(': ')</script>"#,
      #"<a href='/route'>Route</a><button onclick="TelegramWidget.copyText('North')">Copy</button><script>x.innerHTML='<b>'+viewer.name+'</b>';eval("x.value='ready'")</script>"#,
      #"<img src='data:image/gif;base64,R0lGODlhAQABAA=='><script>const a=[65,66];x.textContent=a.map(x=>String.fromCharCode(x)).join('');</script>"#,
      #"<script>x.textContent=`Status ${lookup('key')} done`;x.innerText=atob('SGk=');</script><svg><text>Map</text></svg>"#,
    ].map { Array($0.utf8) }
    var seed: UInt64 = 0x751f_aa09
    func next(_ bound: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      return Int(seed >> 32) % bound
    }
    for iteration in 0..<320 {
      var bytes = documents[next(documents.count)]
      switch iteration % 5 {
      case 0:
        for _ in 0..<1 + next(16) { bytes[next(bytes.count)] ^= UInt8(1 + next(255)) }
      case 1: bytes = Array(bytes.prefix(next(bytes.count)))
      case 2:
        let insert = documents[next(documents.count)]
        bytes.insert(contentsOf: insert, at: next(bytes.count + 1))
      case 3:
        let forms = ["(", "[", "{a:", "`x${", "!"]
        let nested = "<script>" + String(repeating: forms[next(forms.count)], count: 1 + next(8_000)) + "'tail'</script>"
        bytes = Array(nested.utf8)
      default:
        let original = bytes
        while bytes.count < 32_768 { bytes += original }
      }
      bytes = Array(bytes.prefix(32_768))
      let limits = WidgetInspection.Limits(maximumTexts: next(20), maximumTextBytes: next(256),
        maximumTotalTextBytes: next(1_024), maximumActions: next(8), maximumImages: next(4),
        maximumImageBytes: next(64), maximumScriptTokens: 512 + next(2_048),
        maximumFoldingSteps: 512 + next(2_048), maximumNesting: next(4))
      let html = String(decoding: bytes, as: UTF8.self)
      #expect(html.utf8.count <= 32_768)
      let result = WidgetInspection(html: html, publicData: iteration % 7 == 0 ? #"{"a.b":"state","a":{"b":"state"}}"# : nil, limits: limits)
      caps(result, limits)
      if iteration % 16 == 0 {
        var budget = WidgetScriptBudget(limits: limits)
        _ = WidgetScriptAnalysis.analyze(html, isHandler: false, budget: &budget, limits: limits)
        #expect(budget.tokens >= 0 && budget.tokens <= limits.maximumScriptTokens)
        #expect(budget.foldingSteps >= 0 && budget.foldingSteps <= limits.maximumFoldingSteps)
      }
    }
  }
}
