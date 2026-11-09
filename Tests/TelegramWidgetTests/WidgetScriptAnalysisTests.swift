@testable import TelegramWidget
import Testing

@Suite struct WidgetScriptAnalysisTests {
  private func inspect(_ source: String, limits: WidgetInspection.Limits = .init(), handler: Bool = false) -> WidgetScriptAnalysis {
    var budget = WidgetScriptBudget(limits: limits)
    return .analyze(source, isHandler: handler, budget: &budget, limits: limits)
  }

  private func shown(_ result: WidgetScriptAnalysis, _ value: String, _ sink: WidgetInspection.Sink = .textContent) -> Bool {
    result.texts.contains(.init(value, origin: .script(sink)))
  }

  @Test(arguments: [
    (#"'a\n\t\r\b\f\v\0z'"#, "a\n\t\r\u{08}\u{0C}\u{0B}\0z"),
    (#"'\x41\u0042\u{1F31F}'"#, "AB🌟"),
    (#"'\101\12\377\8\9\z'"#, "A\nÿ89z"),
    (#"'\uD83C\uDF1F'"#, "🌟"),
    (#"'\u{0000000041}'"#, "A"),
    ("'a\\\nb'", "ab"),
    ("'a\\\r\nb'", "ab"),
    (#"'\"\'\\'"#, "\"'\\"),
    (#"`a\n${'b'}c`"#, "a\nbc"),
    (#"`a${({ key: `b${'c'}` }).key}d`"#, "abcd"),
    ("`a\r\nb`", "a\nb"),
  ])
  func cookedStrings(_ expression: String, _ expected: String) {
    let result = inspect("x.textContent = \(expression);")
    #expect(shown(result, expected))
    #expect(!result.features.contains(.malformed))
  }

  @Test(arguments: [
    ("1_000 + 0x10 + 0o10 + 0b10", "1026"),
    ("1.5e2 / 3", "50"),
    (".5 + 5.", "5.5"),
    ("077", "63"),
    ("1e20", "100000000000000000000"),
    ("1e21", "1e+21"),
    ("1e-6", "0.000001"),
    ("1e-7", "1e-7"),
    ("-0", "0"),
    ("0 / 0", "NaN"),
    ("1 / 0", "Infinity"),
    ("-1 / 0", "-Infinity"),
    ("1 + true + null", "2"),
    ("1 + undefined", "NaN"),
    (#"'n=' + (1 + 2)"#, "n=3"),
    ("(8 - 2) * 3 % 7", "4"),
    ("(6 ^ 3) | (8 & 10)", "13"),
    ("1 << 33", "2"),
    ("-8 >> 2", "-2"),
    ("-1 >>> 31", "1"),
    ("~0", "-1"),
    (#"'' + [1, null, undefined, [2, 3]]"#, "1,,,2,3"),
    (#"'' + {a: 1}"#, "[object Object]"),
  ])
  func numbersAndCoercions(_ expression: String, _ expected: String) {
    let result = inspect("x.textContent = \(expression);")
    #expect(shown(result, expected))
    #expect(!result.features.contains(.unresolvedOutput))
  }

  @Test(arguments: [
    (#"['a', ...['b', 'c']].join('-')"#, "a-b-c"),
    (#"'abc'.split('').reverse().join('')"#, "cba"),
    (#"'a:b:c'.split(':', 2).join('/')"#, "a/b"),
    (#"'abc'.split().join()"#, "abc"),
    (#"[1, 2].concat([3], 4).join('')"#, "1234"),
    (#"['a', 'b', 'c'].slice(-2).join('')"#, "bc"),
    (#"['a', 'b'].at(-1)"#, "b"),
    (#"'abcdef'.slice(1, -1)"#, "bcde"),
    (#"'abcdef'.substring(4, 1)"#, "bcd"),
    (#"'abcdef'.substr(-3, 2)"#, "de"),
    (#"'a'.concat('b', 2, true, null)"#, "ab2truenull"),
    (#"'Straße'.toUpperCase()"#, "STRASSE"),
    (#"'ABC'.toLowerCase()"#, "abc"),
    (#"'  abc  '.trim()"#, "abc"),
    (#"'  abc  '.trimStart()"#, "abc  "),
    (#"'  abc  '.trimEnd()"#, "  abc"),
    (#"'abcabc'.replace('ab', 'X')"#, "Xcabc"),
    (#"'abcabc'.replaceAll('ab', 'X')"#, "XcXc"),
    (#"'abc'.replace('b', '[$&]$$')"#, "a[b]$c"),
    (#"'abc'.replace('b', "$`-$'")"#, "aa-cc"),
    (#"'ab'.replaceAll('', '-')"#, "-a-b-"),
    (#"'xo'.repeat(3)"#, "xoxoxo"),
    (#"'abc'.charAt(1)"#, "b"),
    (#"'abc'.charCodeAt(1)"#, "98"),
    (#"'🌟'.codePointAt(0)"#, "127775"),
    (#"'abc'.at(-1)"#, "c"),
    (#"'7'.padStart(4, 'ab')"#, "aba7"),
    (#"'7'.padEnd(4, 'ab')"#, "7aba"),
    (#"'🌟'.length"#, "2"),
    (#"'abc'[1]"#, "b"),
    (#"({a: {b: ['no', 'yes']}})['a'].b[1]"#, "yes"),
    (#"JSON.parse('{"a":["first","last"]}').a[1]"#, "last"),
    (#"String.fromCharCode(65, 66, 67)"#, "ABC"),
    (#"String.fromCharCode(...[65, 66, 67])"#, "ABC"),
    (#"String.fromCodePoint(0x1F31F)"#, "🌟"),
    (#"String.fromCharCode(0xD83C) + String.fromCharCode(0xDF1F)"#, "🌟"),
    (#"[79, 110].map(c => String.fromCharCode(c ^ 7)).join('')"#, "Hi"),
    (#"[65, 66].map(function(c) { return String.fromCharCode(c); }).join('')"#, "AB"),
    (#"[65, 66].map((c) => String.fromCharCode(c)).join('')"#, "AB"),
    (#"[65, 66].map(c => { return String.fromCharCode(c); }).join('')"#, "AB"),
    (#"atob('SGVsbG8=')"#, "Hello"),
    (#"atob('S G V s\nbG8')"#, "Hello"),
    (#"atob('/w==').charCodeAt(0)"#, "255"),
    (#"decodeURIComponent('%48%69%20%F0%9F%8C%9F')"#, "Hi 🌟"),
    (#"decodeURI('https%3A%2F%2Fexample.com%2Fa%20b%23c')"#, "https%3A%2F%2Fexample.com%2Fa b%23c"),
    (#"unescape('%u0041%42%uD83C%uDF1F')"#, "AB🌟"),
  ])
  func foldsClosedOperations(_ expression: String, _ expected: String) {
    let result = inspect("x.textContent = \(expression);")
    #expect(shown(result, expected))
    #expect(!result.features.contains(.unresolvedOutput))
    #expect(!result.isTruncated)
  }

  @Test(arguments: [
    ("x.textContent = 'shown'", WidgetInspection.Sink.textContent),
    ("x.textContent += 'shown'", .textContent),
    ("x['textContent'] = 'shown'", .textContent),
    ("x.innerText = 'shown'", .innerText),
    ("x.nodeValue = 'shown'", .nodeValue),
    ("x.value = 'shown'", .value),
    ("x.insertAdjacentText('beforeend', 'shown')", .insertAdjacentText),
    ("document.createTextNode('shown')", .createTextNode),
    ("x.append('shown')", .append),
    ("x.prepend('shown')", .append),
    ("x.before('shown')", .append),
    ("x.after('shown')", .append),
    ("x.replaceChildren('shown')", .append),
    ("x.replaceWith('shown')", .append),
    ("x.append(...['shown'])", .append),
    ("ctx.fillText('shown', 0, 0)", .canvasText),
    ("ctx.strokeText('shown', 1, 2)", .canvasText),
    ("x.setAttribute('title', 'shown')", .setAttribute),
    ("x.setAttribute('aria-label', 'shown')", .setAttribute),
    ("x.setAttribute('alt', 'shown')", .setAttribute),
    ("x.setAttribute('placeholder', 'shown')", .setAttribute),
    ("x.setAttribute('value', 'shown')", .setAttribute),
    ("x.setAttribute('label', 'shown')", .setAttribute),
    ("x.title = 'shown'", .setAttribute),
    ("x.alt = 'shown'", .setAttribute),
    ("x.placeholder = 'shown'", .setAttribute),
  ])
  func textSinks(_ source: String, _ sink: WidgetInspection.Sink) {
    let result = inspect(source)
    #expect(shown(result, "shown", sink))
    #expect(!result.texts.contains(.init("shown", origin: .scriptLiteral)))
  }

  @Test(arguments: [
    ("x.innerHTML = '<b>text</b>'", WidgetInspection.Sink.innerHTML),
    ("x.innerHTML += '<b>text</b>'", .innerHTML),
    ("x.outerHTML = '<b>text</b>'", .outerHTML),
    ("x.outerHTML += '<b>text</b>'", .outerHTML),
    ("x.insertAdjacentHTML('beforeend', '<b>text</b>')", .insertAdjacentHTML),
    ("document.write('<b>text</b>')", .documentWrite),
    ("document.writeln('<b>text</b>')", .documentWrite),
    ("x.append(new DOMParser().parseFromString('<b>text</b>', 'text/html'))", .innerHTML),
    ("x.appendChild(document.createRange().createContextualFragment('<b>text</b>'))", .innerHTML),
    ("const f = new DOMParser().parseFromString('<b>text</b>', 'text/html'); x.replaceChildren(f)", .innerHTML),
  ])
  func htmlSinks(_ source: String, _ sink: WidgetInspection.Sink) {
    let result = inspect(source)
    #expect(result.htmlFragments.contains(.init(html: "<b>text</b>", sink: sink)))
    #expect(!result.texts.contains(.init("<b>text</b>", origin: .scriptLiteral)))
  }

  @Test(arguments: [
    ("TelegramWidget.openLink('target')", WidgetInspection.Action.Kind.openLink),
    ("window.TelegramWidget.openTelegramLink('target')", .openTelegramLink),
    ("TelegramWidget.copyText('target')", .copyText),
    ("TelegramWidget.request('target', {wallet: true})", .request),
    ("TelegramWidget.wallet.sendTransaction('target')", .walletSendTransaction),
    ("TelegramWidget.wallet.signData('target')", .walletSignData),
    ("window.open('target')", .openLink),
    ("location.href = 'target'", .openLink),
    ("window.location.href = 'target'", .openLink),
    ("location.assign('target')", .openLink),
    ("location.replace('target')", .openLink),
    ("x.href = 'target'", .anchor),
    ("x.setAttribute('href', 'target')", .anchor),
    ("const tw = window.TelegramWidget; tw.openLink('target')", .openLink),
    ("const {openLink} = TelegramWidget; openLink('target')", .openLink),
    ("const {copyText: copy} = TelegramWidget; copy('target')", .copyText),
    ("const wallet = TelegramWidget.wallet; wallet.signData('target')", .walletSignData),
    ("const loc = location; loc.href = 'target'", .openLink),
  ])
  func actionSinks(_ source: String, _ kind: WidgetInspection.Action.Kind) {
    let result = inspect(source)
    #expect(result.actions.contains(.init(kind: kind, target: "target")))
    #expect(!result.features.contains(.unresolvedAction))
    #expect(!result.texts.contains(.init("target", origin: .scriptLiteral)))
  }

  @Test func aliasesAndDestructuring() {
    let result = inspect(#"""
      const d = document;
      const el = d.getElementById('item');
      const {label: title} = {label: 'Header'};
      const [, tail] = ['first', 'Tail'];
      el.textContent = title + tail;
      d.write('<i>Written</i>');
      """#)
    #expect(shown(result, "HeaderTail"))
    #expect(result.htmlFragments.contains(.init(html: "<i>Written</i>", sink: .documentWrite)))
    #expect(!result.texts.contains(.init("Header", origin: .scriptLiteral)))
  }

  @Test func escapedIdentifiersAndComments() {
    let result = inspect(#"""
      // 'ignored' atob('x')
      /* "also ignored" eval('x') */
      <!-- 'hidden comment'
      --> 'another comment'
      const t\u0077 = window.TelegramWidget;
      tw.openL\u0069nk('link');
      x.textC\u006fntent = 'visible';
      """#)
    #expect(result.actions.contains(.init(kind: .openLink, target: "link")))
    #expect(shown(result, "visible"))
    #expect(!result.features.contains(.base64))
    #expect(!result.features.contains(.dynamicCode))
    #expect(!result.features.contains(.malformed))
  }

  @Test func regexAndDivision() {
    let result = inspect(#"""
      const r = /[/'"]+\//gi;
      if (flag) /"atob('in regex')"/.test(value);
      x.textContent = 12 / 3 / 2;
      x.innerText = 'after';
      """#)
    #expect(shown(result, "2"))
    #expect(shown(result, "after", .innerText))
    #expect(!result.features.contains(.base64))
    #expect(!result.features.contains(.malformed))
  }

  @Test(arguments: ["'unterminated", "`unfinished ${'ok'", "/* unfinished", "/unfinished[", #"'bad\xQZ'"#, #"'bad\u{110000}'"#, "'line\nbreak", #"`bad\1`"#])
  func malformedInput(_ source: String) {
    #expect(inspect(source).features.contains(.malformed))
  }

  @Test func partialOutputsAndUnprovenLiterals() {
    let result = inspect(#"""
      const unused = 'unproven';
      x.textContent = 'Hello ' + viewer.name + ('from' + ' here');
      x.innerText = `Status: ${state.label} ready`;
      x.value = ['a', state.value, 'b'].join('');
      x.innerHTML = `<b>${state.name}</b>`;
      x.placeholder = list.map(item => 'Item: ' + item.name).join('');
      TelegramWidget.openLink('https://example.com/' + state.path);
      """#)
    #expect(shown(result, "Hello "))
    #expect(shown(result, "from here"))
    #expect(shown(result, "Status: ", .innerText))
    #expect(shown(result, " ready", .innerText))
    #expect(shown(result, "a", .value))
    #expect(shown(result, "b", .value))
    #expect(shown(result, "Item: ", .setAttribute))
    #expect(result.htmlFragments.contains(.init(html: "<b></b>", sink: .innerHTML)))
    let numeric = inspect(#"x.innerHTML = `<b>${1 + 2}:${state}</b>`"#)
    #expect(numeric.htmlFragments.contains(.init(html: "<b>3:</b>", sink: .innerHTML)))
    #expect(result.features.contains([.unresolvedOutput, .unresolvedAction]))
    #expect(result.actions.contains(.init(kind: .openLink, target: nil)))
    #expect(result.texts.contains(.init("unproven", origin: .scriptLiteral)))
    #expect(result.texts.contains(.init("https://example.com/", origin: .scriptLiteral)))
    #expect(!result.texts.contains(.init("Hello ", origin: .scriptLiteral)))
  }

  @Test(arguments: [
    "let value = 'initial'; value = runtime; x.textContent = value;",
    "var value = 'initial'; x.textContent = value; value += runtime;",
    "const value = 'initial'; function f(value) { x.textContent = value; }",
    "let value = 'initial'; value++; x.textContent = value;",
    "const value = {a: 'initial'}; value.a = runtime; x.textContent = value.a;",
    "const value = ['initial']; value.push(runtime); x.textContent = value.join('');",
    "const value = {a: 'initial'}; const alias = value; alias.a = runtime; x.textContent = value.a;",
    "let value = 'initial'; {let value = runtime; x.textContent = value;}",
  ])
  func changedBindingsAreUnknown(_ source: String) {
    let result = inspect(source)
    #expect(result.features.contains(.unresolvedOutput))
    #expect(!shown(result, "initial"))
  }

  @Test func dataURLs() {
    let result = inspect("const url = 'data:image/png;base64,AQ=='; img.src = url; img.setAttribute('src', url)")
    #expect(result.dataURLs == ["data:image/png;base64,AQ=="])
  }

  @Test func allFeatures() {
    let result = inspect(#"""
      setTimeout(callback, 10); setInterval(callback, 20); requestAnimationFrame(callback);
      eval(source); Function(source); String.fromCharCode(65); atob('QQ=='); decodeURI('%41');
      TelegramWidget.publicData; TelegramWidget.chatData; TelegramWidget.watchPublicData();
      localStorage; sessionStorage; TelegramWidget.viewer; TelegramWidget.chatType;
      TelegramWidget.isForward; TelegramWidget.isPreview;
      Date.now(); performance.now(); Math.random(); crypto.getRandomValues(buffer); crypto.randomUUID();
      canvas.getContext('2d').fillText(text, 0, 0);
      TelegramWidget.request(data); TelegramWidget.wallet.signData(payload);
      """#)
    let expected: WidgetInspection.Features = [
      .script, .timers, .dynamicCode, .characterCodes, .base64, .uriDecoding,
      .readsState, .watchesState, .storage, .readsContext, .clockOrRandomness,
      .canvas, .canvasText, .requests, .wallet, .unresolvedOutput, .unresolvedAction,
    ]
    #expect(result.features.isSuperset(of: expected))
    #expect(inspect("'atob eval Date publicData viewer getContext request wallet'").features == .script)
    #expect(inspect("TelegramWidget.onEvent('publicDataChanged', fn)").features.contains(.readsState))
    #expect(inspect("TelegramWidget.onEvent('chatDataChanged', fn)").features.contains(.readsState))
    #expect(inspect("'publicDataChanged'").features == .script)
    #expect(inspect("").features.isEmpty)
  }

  @Test(arguments: [
    #"eval(atob('eC50ZXh0Q29udGVudCA9ICdSZWNvdmVyZWQn'))"#,
    #"Function("x.textContent = 'Recovered'")"#,
    #"new Function('arg', "x.textContent = 'Recovered'")"#,
    #"setTimeout("x.textContent = 'Recovered'", 1)"#,
  ])
  func recoveredScripts(_ source: String) {
    let result = inspect(source)
    #expect(shown(result, "Recovered"))
    #expect(result.features.contains(.dynamicCode))
    let limited = inspect(source, limits: .init(maximumNesting: 0))
    #expect(limited.isTruncated)
    #expect(!shown(limited, "Recovered"))
  }

  @Test func budgetsAndCaps() {
    let source = "x.textContent = 'hello' + ' world';"
    let tokenLimited = inspect(source, limits: .init(maximumScriptTokens: 3))
    #expect(tokenLimited.isTruncated)
    let foldingLimited = inspect(source, limits: .init(maximumFoldingSteps: 1))
    #expect(foldingLimited.isTruncated)
    #expect(!shown(foldingLimited, "hello world"))
    let expansion = inspect("x.textContent = 'x'.repeat(1e9)")
    #expect(expansion.isTruncated)
    #expect(expansion.features.contains(.unresolvedOutput))
    let padding = inspect("x.textContent = 'x'.padEnd(1e9)")
    #expect(padding.isTruncated)
    let nested = inspect(String(repeating: "(", count: 1_000) + "'x'" + String(repeating: ")", count: 1_000))
    #expect(nested.isTruncated)
    var budget = WidgetScriptBudget(limits: .init(maximumScriptTokens: 5))
    _ = WidgetScriptAnalysis.analyze(source, isHandler: false, budget: &budget, limits: .init())
    #expect(budget.tokens == 0)
    let second = WidgetScriptAnalysis.analyze(source, isHandler: true, budget: &budget, limits: .init())
    #expect(second.isTruncated)
  }

  @Test func inlineHandlerAndLiteralDeduplication() {
    let result = inspect("x.textContent = 'display'; 'other'; 'other'; '   '; ('fold' + 'ed');", handler: true)
    #expect(shown(result, "display"))
    #expect(result.texts.filter { $0 == .init("other", origin: .scriptLiteral) }.count == 1)
    #expect(result.texts.contains(.init("folded", origin: .scriptLiteral)))
    #expect(!result.texts.contains(.init("   ", origin: .scriptLiteral)))
  }

  @Test(arguments: [
    #"unknown('candidate')"#, #"'a'.replace(/a/, 'candidate')"#,
    #"[1, 2].filter(c => 'candidate').join('')"#,
    #"1n + 2n"#, #"atob('!!!')"#, #"decodeURIComponent('%FF')"#,
    #"String.fromCodePoint(0x110000)"#, #"JSON.parse('invalid')"#,
  ])
  func unsupportedExpressionsStayUnknown(_ expression: String) {
    #expect(inspect("x.textContent = \(expression)").features.contains(.unresolvedOutput))
  }

  @Test(arguments: [
    (#"'a'.charAt(50) + 'end'"#, "end"),
    (#"'a'.charCodeAt(50)"#, "NaN"),
    (#"'a'.codePointAt(50)"#, "undefined"),
    (#"'a'.at(-2)"#, "undefined"),
    (#"'abc'.slice(-100, 100)"#, "abc"),
    (#"'abc'.substring(-1, 2)"#, "ab"),
    (#"'a'.split('', 0).join('') + 'end'"#, "end"),
    (#"[1, null, undefined].join()"#, "1,,"),
    (#"'ababa'.replaceAll('aba', 'X')"#, "Xba"),
    (#"'abc'.replace('x', 'X')"#, "abc"),
    (#"'abc'.replace('b', '$1')"#, "a$1c"),
    (#"'a'.padEnd(3)"#, "a  "),
    (#"'a'.padStart(3, '')"#, "a"),
    (#"'abc'['toUpperCase']()"#, "ABC"),
    (#"String['fromCharCode'](65)"#, "A"),
    (#"unescape('%Q0%uZZZZ')"#, "%Q0%uZZZZ"),
    (#"String.fromCharCode(65537, -65471)"#, "\u{01}A"),
    (#"('\uD800'.toLowerCase()).charCodeAt(0)"#, "55296"),
    (#"JSON.parse('[true, null, 1.5]').join('-')"#, "true--1.5"),
    ("'a\u{2028}b\u{2029}c'", "a\u{2028}b\u{2029}c"),
  ])
  func operationEdges(_ expression: String, _ expected: String) {
    let result = inspect("x.textContent = \(expression)")
    #expect(shown(result, expected))
    #expect(result.features.isDisjoint(with: [.unresolvedOutput, .malformed]))
  }

  @Test func lexicalBoundaries() {
    let result = inspect(#"""
      const a = {n: 1} / 2;
      if (flag) { const x = 1; } /"ignored"/.test(value);
      const t = `head ${ {a: '}', b: `${'nested'}`}.b } tail`;
      x.textContent = t;
      x.innerText = 6 / /x/.source.length;
      """#)
    #expect(shown(result, "head nested tail"))
    #expect(!result.features.contains(.malformed))
    #expect(!result.texts.contains(.init("ignored", origin: .scriptLiteral)))
    #expect(inspect(#"const map = {'literal key': 1};"#).texts.contains(.init("literal key", origin: .scriptLiteral)))
  }

  @Test func insertedParserBodyAndUninsertedMarkup() {
    let inserted = inspect(#"const doc = new DOMParser().parseFromString('<b>body</b>', 'text/html'); x.append(doc.body)"#)
    #expect(inserted.htmlFragments.contains(.init(html: "<b>body</b>", sink: .innerHTML)))
    let unused = inspect(#"new DOMParser().parseFromString('<b>unused</b>', 'text/html')"#)
    #expect(unused.htmlFragments.isEmpty)
    #expect(unused.texts.contains(.init("<b>unused</b>", origin: .scriptLiteral)))
  }

  @Test func unknownActionsAndWalletObjects() {
    let result = inspect(#"""
      TelegramWidget.wallet.signData({text: 'terms'});
      TelegramWidget.request(runtime);
      TelegramWidget.copyText(runtime);
      location.href = runtime;
      """#)
    #expect(result.actions.contains(.init(kind: .walletSignData, target: nil)))
    #expect(result.actions.contains(.init(kind: .request, target: nil)))
    #expect(result.actions.contains(.init(kind: .copyText, target: nil)))
    #expect(result.actions.contains(.init(kind: .openLink, target: nil)))
    #expect(result.features.contains(.unresolvedAction))
    #expect(result.texts.contains(.init("terms", origin: .scriptLiteral)))
  }

  @Test func aliasesOfFoldingFunctions() {
    let result = inspect(#"""
      const {fromCharCode: chars} = String;
      const decode = atob;
      const prefix = 'greeting: ';
      const codes = [72, 105];
      x.textContent = prefix + chars(...codes) + decode('IQ==');
      """#)
    #expect(shown(result, "greeting: Hi!"))
    #expect(result.features.contains([.base64, .characterCodes]))
  }

  @Test(arguments: [
    "const String = runtime; x.textContent = String.fromCharCode(65)",
    "String.fromCharCode = custom; x.textContent = String.fromCharCode(65)",
    "const S = String; S.fromCharCode = custom; x.textContent = String.fromCharCode(65)",
    "Array.prototype.join = custom; x.textContent = ['a'].join('')",
    "const value = 'first'; ++value; x.textContent = value",
    "const value = {a: 'first'}; delete value.a; x.textContent = value.a",
    "const value = 'first'; [value] = runtime; x.textContent = value",
    "const value = 'first'; ({a: value} = runtime); x.textContent = value",
    "const value = 'first'; for (value of runtime) { x.textContent = value }",
    "const value = 'first'; for (const value of runtime) { x.textContent = value }",
    "const value = 'first'; try {} catch (value) { x.textContent = value }",
    "const value = 'first'; const f = (value, other) => x.textContent = value",
    "class String {}; x.textContent = String.fromCharCode(65)",
  ])
  func shadowedAndModifiedValues(_ source: String) {
    #expect(inspect(source).features.contains(.unresolvedOutput))
  }

  @Test func operationCapsNeverReturnPartialConstants() {
    for expression in [
      "'x'.repeat(5000).split('', 100000).join('')",
      "'x'.repeat(5000).split('', undefined).join('')",
      "'x,'.repeat(5000).split(',', 100000).join('')",
      "'x'.repeat(100).replaceAll('x', 'y'.repeat(1000))",
    ] {
      let result = inspect("x.textContent = \(expression)")
      #expect(result.isTruncated)
      #expect(result.features.contains(.unresolvedOutput))
    }
    let json = String(repeating: "[", count: 70) + "0" + String(repeating: "]", count: 70)
    let result = inspect("x.textContent = JSON.parse('\(json)')")
    #expect(result.isTruncated)
    #expect(result.features.contains(.unresolvedOutput))
  }

  @Test func aggregateAndInvalidLimits() {
    let result = inspect(#"x.textContent = 'first'; eval("x.innerText = 'second'");"#, limits: .init(maximumTexts: 1, maximumTotalTextBytes: 5))
    #expect(result.texts.count <= 1)
    #expect(result.texts.reduce(0) { $0 + $1.value.utf8.count } <= 5)
    #expect(result.isTruncated)
    let unicode = inspect("x.textContent = '🌟🌟'", limits: .init(maximumTextBytes: 5))
    #expect(shown(unicode, "🌟"))
    #expect(unicode.isTruncated)
    let invalid = inspect("x.textContent = 'text'", limits: .init(
      maximumTexts: .min, maximumTextBytes: .min, maximumTotalTextBytes: .min,
      maximumActions: .min, maximumScriptTokens: .min, maximumFoldingSteps: .min, maximumNesting: .min))
    #expect(invalid.isTruncated)
  }

  @Test func nestedDynamicCodeSharesDepthAndWork() {
    let source = #"eval("eval(\"x.textContent = 'deep'\")")"#
    let one = inspect(source, limits: .init(maximumNesting: 1))
    #expect(one.isTruncated)
    #expect(!shown(one, "deep"))
    #expect(shown(inspect(source, limits: .init(maximumNesting: 2)), "deep"))
    let limited = inspect(source, limits: .init(maximumScriptTokens: 12))
    #expect(limited.isTruncated)
  }

  @Test func boundedMalformedSamples() {
    // Synthetic text only: exercise the reader, never a JavaScript runtime.
    let alphabet = Array("ab01'\"`$/{[()]}\\+*;:=,\n ")
    var seed: UInt64 = 1
    for _ in 0..<500 {
      var source = ""
      for _ in 0..<96 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        source.append(alphabet[Int(seed % UInt64(alphabet.count))])
      }
      let limits = WidgetInspection.Limits(maximumScriptTokens: 256, maximumFoldingSteps: 256)
      var budget = WidgetScriptBudget(limits: limits)
      _ = WidgetScriptAnalysis.analyze(source, isHandler: false, budget: &budget, limits: limits)
      #expect(budget.tokens >= 0)
      #expect(budget.foldingSteps >= 0)
    }
    let large = String(repeating: "x.textContent = 'sample';", count: 1_365)
    #expect(!inspect(large).features.contains(.malformed))
    let templates = String(repeating: "`a${", count: 200) + "0" + String(repeating: "}`", count: 200)
    #expect(inspect(templates).isTruncated)
    let deepArray = "x.textContent = ['prefix', " + String(repeating: "[", count: 200)
      + "'inner'" + String(repeating: "]", count: 200) + "].join('')"
    let partial = inspect(deepArray)
    #expect(partial.isTruncated)
    #expect(partial.features.contains(.unresolvedOutput))
  }


  @Test func cutArgumentsCannotBecomeCompleteValues() {
    let result = inspect("x.textContent = 'prefix' + runtime", limits: .init(maximumScriptTokens: 5))
    #expect(result.isTruncated)
    #expect(result.features.contains(.unresolvedOutput))
    #expect(!result.features.contains(.malformed))
    #expect(shown(result, "prefix"))
    let action = inspect("TelegramWidget.openLink('prefix' + runtime)", limits: .init(maximumScriptTokens: 5))
    #expect(action.actions.contains(.init(kind: .openLink, target: nil)))
    #expect(action.isTruncated)
    #expect(!action.features.contains(.malformed))
    let appended = inspect("location.href += 'tail'")
    #expect(appended.actions.contains(.init(kind: .openLink, target: nil)))
    #expect(!appended.actions.contains(.init(kind: .openLink, target: "tail")))
  }


  @Test(arguments: ["1e+_2", "1__0", "0x_FF", "0b2", "1_", "0_1"])
  func malformedNumbers(_ source: String) {
    #expect(inspect(source).features.contains(.malformed))
  }

}
