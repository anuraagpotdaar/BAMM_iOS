// Swift port of clip.simple_tokenizer (CLIP BPE). Reads bpe_simple_vocab_16e6.txt.gz
// from Resources/Bamm2 and emits (1, 77) Int32 tokens.

import Foundation
import Compression

enum BpeError: Error, CustomStringConvertible {
    case vocabMissing
    case vocabRead(String)
    var description: String {
        switch self {
        case .vocabMissing:        return "BPE vocab file not found in bundle"
        case .vocabRead(let why):  return "BPE vocab read failed: \(why)"
        }
    }
}

final class ClipBpeTokenizer {
    static let contextLength = 77
    static let sotToken = "<|startoftext|>"
    static let eotToken = "<|endoftext|>"

    private let encoder: [String: Int32]
    private let bpeRanks: [String: Int]
    private let byteEncoder: [UInt8: String]
    private let sotId: Int32
    private let eotId: Int32

    private var cache: [String: String] = [
        ClipBpeTokenizer.sotToken: ClipBpeTokenizer.sotToken,
        ClipBpeTokenizer.eotToken: ClipBpeTokenizer.eotToken,
    ]

    private static var patterns: [NSRegularExpression] {
        let raw = [
            #"<\|startoftext\|>"#,
            #"<\|endoftext\|>"#,
            #"'s|'t|'re|'ve|'m|'ll|'d"#,
            #"\p{L}+"#,
            #"\p{N}"#,
            #"[^\s\p{L}\p{N}]+"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    init(bundleResourceName: String = "bpe_simple_vocab_16e6", ext: String = "txt.gz") throws {
        // Resources/Bamm2 is a folder reference — try subdirectory first, fall back to flat root.
        let url = Bundle.main.url(forResource: bundleResourceName, withExtension: ext, subdirectory: "Bamm2")
            ?? Bundle.main.url(forResource: bundleResourceName, withExtension: ext)
        guard let url else { throw BpeError.vocabMissing }
        let gz = try Data(contentsOf: url)
        let txt = try Self.gunzipToString(gz)
        let lines = txt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let mergeRange = 1..<(49152 - 256 - 2 + 1)
        let merges: [[String]] = lines[mergeRange].map { $0.split(separator: " ").map(String.init) }

        let (be, _) = Self.bytesToUnicode()
        self.byteEncoder = be

        var vocab: [String] = []
        vocab.append(contentsOf: be.values)
        vocab.append(contentsOf: be.values.map { $0 + "</w>" })
        for m in merges { vocab.append(m.joined()) }
        vocab.append(Self.sotToken)
        vocab.append(Self.eotToken)
        var encoder: [String: Int32] = [:]
        encoder.reserveCapacity(vocab.count)
        for (i, t) in vocab.enumerated() { encoder[t] = Int32(i) }
        self.encoder = encoder

        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (i, m) in merges.enumerated() { ranks[m.joined(separator: " ")] = i }
        self.bpeRanks = ranks

        guard let sot = encoder[Self.sotToken], let eot = encoder[Self.eotToken] else {
            throw BpeError.vocabRead("missing sot/eot in encoder")
        }
        self.sotId = sot
        self.eotId = eot
    }

    func tokenize(_ text: String) -> [Int32] {
        var tokens: [Int32] = [sotId]
        tokens.append(contentsOf: encode(text))
        tokens.append(eotId)
        if tokens.count > Self.contextLength {
            tokens = Array(tokens.prefix(Self.contextLength))
            tokens[Self.contextLength - 1] = eotId
        } else {
            tokens.append(contentsOf: Array(repeating: Int32(0), count: Self.contextLength - tokens.count))
        }
        return tokens
    }

    private func encode(_ raw: String) -> [Int32] {
        let normalized = whitespaceClean(basicClean(raw)).lowercased()
        var out: [Int32] = []
        for word in regexFindAll(in: normalized) {
            var bytesAsString = ""
            for b in word.utf8 { bytesAsString += byteEncoder[b] ?? "" }
            let merged = bpe(bytesAsString)
            for piece in merged.split(separator: " ") {
                if let id = encoder[String(piece)] { out.append(id) }
            }
        }
        return out
    }

    // Walk left-to-right, longest pattern match wins.
    private func regexFindAll(in text: String) -> [String] {
        var out: [String] = []
        let ns = text as NSString
        var loc = 0
        while loc < ns.length {
            var bestRange = NSRange(location: NSNotFound, length: 0)
            for p in Self.patterns {
                if let m = p.firstMatch(in: text, options: [.anchored], range: NSRange(location: loc, length: ns.length - loc)) {
                    if bestRange.location == NSNotFound || m.range.length > bestRange.length {
                        bestRange = m.range
                    }
                }
            }
            if bestRange.location == NSNotFound {
                loc += 1
            } else {
                out.append(ns.substring(with: bestRange))
                loc += max(bestRange.length, 1)
            }
        }
        return out
    }

    private func bpe(_ token: String) -> String {
        if let cached = cache[token] { return cached }
        guard let last = token.last else { return token + "</w>" }
        var word: [String] = []
        let chars = Array(token)
        if chars.count == 1 {
            word = [String(last) + "</w>"]
        } else {
            for i in 0..<(chars.count - 1) { word.append(String(chars[i])) }
            word.append(String(last) + "</w>")
        }
        var pairs = Self.getPairs(word)
        if pairs.isEmpty {
            let result = token + "</w>"
            cache[token] = result
            return result
        }
        while true {
            // Find the lowest-rank bigram
            var best: (String, String)? = nil
            var bestRank = Int.max
            for (a, b) in pairs {
                if let r = bpeRanks["\(a) \(b)"], r < bestRank { bestRank = r; best = (a, b) }
            }
            guard let (first, second) = best else { break }
            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if let j = word[i...].firstIndex(of: first) {
                    newWord.append(contentsOf: word[i..<j])
                    i = j
                } else {
                    newWord.append(contentsOf: word[i..<word.count])
                    break
                }
                if word[i] == first && i + 1 < word.count && word[i + 1] == second {
                    newWord.append(first + second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
            pairs = Self.getPairs(word)
        }
        let result = word.joined(separator: " ")
        cache[token] = result
        return result
    }

    private static func getPairs(_ word: [String]) -> [(String, String)] {
        guard word.count > 1 else { return [] }
        var seen = Set<String>()
        var out: [(String, String)] = []
        for i in 0..<(word.count - 1) {
            let key = "\(word[i])\t\(word[i + 1])"
            if !seen.contains(key) {
                seen.insert(key)
                out.append((word[i], word[i + 1]))
            }
        }
        return out
    }

    private func basicClean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "&amp;",  with: "&")
        t = t.replacingOccurrences(of: "&lt;",   with: "<")
        t = t.replacingOccurrences(of: "&gt;",   with: ">")
        t = t.replacingOccurrences(of: "&quot;", with: "\"")
        t = t.replacingOccurrences(of: "&apos;", with: "'")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func whitespaceClean(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func bytesToUnicode() -> ([UInt8: String], [String: UInt8]) {
        var bs: [Int] = Array(Int("!".unicodeScalars.first!.value)...Int("~".unicodeScalars.first!.value))
        bs.append(contentsOf: Array(0xA1...0xAC))
        bs.append(contentsOf: Array(0xAE...0xFF))
        var cs = bs
        var n = 0
        for b in 0..<256 {
            if !bs.contains(b) {
                bs.append(b); cs.append(256 + n); n += 1
            }
        }
        var be: [UInt8: String] = [:]
        var bd: [String: UInt8] = [:]
        for i in 0..<bs.count {
            let chrStr = String(UnicodeScalar(cs[i])!)
            be[UInt8(bs[i])] = chrStr
            bd[chrStr] = UInt8(bs[i])
        }
        return (be, bd)
    }

    // Strip gzip header + CRC trailer; Compression framework wants raw DEFLATE.
    private static func gunzipToString(_ data: Data) throws -> String {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b else {
            throw BpeError.vocabRead("not gzip")
        }
        let flags = data[3]
        var offset = 10
        if (flags & 0x08) != 0 { while offset < data.count && data[offset] != 0 { offset += 1 }; offset += 1 }
        if (flags & 0x10) != 0 { while offset < data.count && data[offset] != 0 { offset += 1 }; offset += 1 }
        let body = data.subdata(in: offset..<(data.count - 8))
        let bufferSize = max(body.count * 12, 16 * 1024 * 1024)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }
        let decoded = body.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Int in
            let src = rawBuf.bindMemory(to: UInt8.self).baseAddress!
            return compression_decode_buffer(dst, bufferSize, src, body.count, nil, COMPRESSION_ZLIB)
        }
        guard decoded > 0 else { throw BpeError.vocabRead("decompress failed") }
        let outData = Data(bytes: dst, count: decoded)
        guard let s = String(data: outData, encoding: .utf8) else {
            throw BpeError.vocabRead("utf8 decode failed")
        }
        return s
    }
}
