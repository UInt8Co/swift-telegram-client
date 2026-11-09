// Only headers are inspected. Image bytes are never rendered or decompressed.
enum WidgetImageReader: Sendable {
  enum Decoded: Sendable {
    case image(WidgetInspection.Image), tooLarge, invalid
  }

  static func decode(_ url: String, maximumBytes: Int) -> Decoded {
    guard url.prefix(5).lowercased() == "data:", let comma = url.firstIndex(of: ",") else { return .invalid }
    let metadata = url[url.index(url.startIndex, offsetBy: 5)..<comma].split(separator: ";", omittingEmptySubsequences: false)
    let mediaType = metadata.first.map { WidgetReading.trim(String($0)).lowercased() } ?? ""
    let base64 = metadata.dropFirst().contains { $0.lowercased() == "base64" }
    let input = Array(url[url.index(after: comma)...].utf8)
    var bytes: [UInt8] = []
    var index = 0
    var accumulator = 0
    var bits = 0
    var padding = 0
    var digits = 0
    func hex(_ c: UInt8) -> Int? {
      switch c {
      case 48...57: Int(c - 48)
      case 65...70: Int(c - 55)
      case 97...102: Int(c - 87)
      default: nil
      }
    }
    while index < input.count {
      var byte = input[index]; index += 1
      if byte == 37 {
        guard input.count - index >= 2, let high = hex(input[index]), let low = hex(input[index + 1]) else { return .invalid }
        byte = UInt8(high * 16 + low)
        index += 2
      }
      if base64 {
        if [9, 10, 12, 13, 32].contains(byte) { continue }
        if byte == 61 { padding += 1; if padding > 2 { return .invalid }; continue }
        guard padding == 0 else { return .invalid }
        let digit: Int
        switch byte {
        case 65...90: digit = Int(byte - 65)
        case 97...122: digit = Int(byte - 71)
        case 48...57: digit = Int(byte + 4)
        case 43: digit = 62
        case 47: digit = 63
        default: return .invalid
        }
        digits += 1
        accumulator = (accumulator << 6 | digit) & 0xffff
        bits += 6
        if bits < 8 { continue }
        bits -= 8
        byte = UInt8((accumulator >> bits) & 255)
      }
      guard bytes.count < max(0, maximumBytes) else { return .tooLarge }
      bytes.append(byte)
    }
    if base64 {
      guard digits % 4 != 1, padding == 0 || (digits + padding) % 4 == 0,
        (bits == 0 || accumulator & ((1 << bits) - 1) == 0) else { return .invalid }
    }
    let header = identify(bytes)
    return .image(.init(format: header.0, declaredMediaType: mediaType, width: header.1, height: header.2, data: bytes))
  }

  private static func identify(_ b: [UInt8]) -> (WidgetInspection.Image.Format, Int?, Int?) {
    func matches(_ offset: Int, _ signature: [UInt8]) -> Bool {
      offset <= b.count && signature.count <= b.count - offset
        && b[offset..<(offset + signature.count)].elementsEqual(signature)
    }
    func little(_ offset: Int, _ count: Int) -> Int {
      (0..<count).reduce(0) { $0 | Int(b[offset + $1]) << ($1 * 8) }
    }
    func big(_ offset: Int, _ count: Int) -> Int {
      (0..<count).reduce(0) { $0 << 8 | Int(b[offset + $1]) }
    }
    if matches(0, [137, 80, 78, 71, 13, 10, 26, 10]) {
      if b.count >= 24, matches(12, Array("IHDR".utf8)) { return (.png, big(16, 4), big(20, 4)) }
      return (.png, nil, nil)
    }
    if matches(0, Array("GIF87a".utf8)) || matches(0, Array("GIF89a".utf8)) {
      return b.count >= 10 ? (.gif, little(6, 2), little(8, 2)) : (.gif, nil, nil)
    }
    if matches(0, [255, 216, 255]) {
      var i = 2
      let frames: Set<UInt8> = [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]
      while i < b.count {
        guard b[i] == 255 else { break }
        while i < b.count, b[i] == 255 { i += 1 }
        guard i < b.count else { break }
        let marker = b[i]; i += 1
        if marker == 0xda || marker == 0xd9 { break }
        if marker == 0x01 || (0xd0...0xd8).contains(marker) { continue }
        guard b.count - i >= 2 else { break }
        let length = big(i, 2)
        guard length >= 2, length <= b.count - i else { break }
        if frames.contains(marker), length >= 7 { return (.jpeg, big(i + 5, 2), big(i + 3, 2)) }
        i += length
      }
      return (.jpeg, nil, nil)
    }
    if matches(0, Array("RIFF".utf8)), matches(8, Array("WEBP".utf8)) {
      var i = 12
      while b.count - i >= 8 {
        let length = little(i + 4, 4)
        let body = i + 8
        guard length <= b.count - body else { break }
        if matches(i, Array("VP8X".utf8)), length >= 10 {
          return (.webp, little(body + 4, 3) + 1, little(body + 7, 3) + 1)
        }
        if matches(i, Array("VP8L".utf8)), length >= 5, b[body] == 0x2f {
          let packed = little(body + 1, 4)
          return (.webp, (packed & 0x3fff) + 1, ((packed >> 14) & 0x3fff) + 1)
        }
        if matches(i, Array("VP8 ".utf8)), length >= 10, matches(body + 3, [0x9d, 1, 0x2a]) {
          return (.webp, little(body + 6, 2) & 0x3fff, little(body + 8, 2) & 0x3fff)
        }
        i = body + length + (length & 1)
      }
      return (.webp, nil, nil)
    }
    let text = WidgetReading.trim(String(decoding: b.prefix(1_024), as: UTF8.self))
      .drop(while: { $0 == "\u{feff}" }).lowercased()
    if text.hasPrefix("<svg") || (text.hasPrefix("<?xml") && text.contains("<svg")) {
      return (.svg, nil, nil)
    }
    return (.unknown, nil, nil)
  }

  static func sources(_ srcset: String) -> [String] {
    let s = Array(srcset.unicodeScalars)
    var i = 0
    var urls: [String] = []
    while i < s.count {
      while i < s.count, WidgetReading.space(s[i]) || s[i] == "," { i += 1 }
      let start = i
      while i < s.count, !WidgetReading.space(s[i]) { i += 1 }
      var end = i
      while end > start, s[end - 1] == "," { end -= 1 }
      if end > start { urls.append(WidgetReading.string(s[start..<end])) }
      if end != i { continue }
      // Descriptors follow the URL, ending at a comma outside parentheses.
      var parentheses = 0
      while i < s.count {
        let c = s[i]; i += 1
        if c == "(" { parentheses += 1 }
        if c == ")" { parentheses = max(0, parentheses - 1) }
        if c == ",", parentheses == 0 { break }
      }
    }
    return urls
  }
}
