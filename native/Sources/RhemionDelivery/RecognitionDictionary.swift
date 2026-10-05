import Foundation

/// Personal recognition dictionary: whole-word, case-insensitive variant -> canonical
/// replacements applied to recognized text, loaded from the compiled-JSON (v1) format.
public struct RecognitionDictionary: Sendable, Equatable {
    /// Normalized, deterministically ordered replacement pairs (variant, canonical).
    /// Sorted so `Equatable` is order-independent of the caller's input order.
    private let replacements: [(String, String)]

    public static let empty = RecognitionDictionary(replacements: [])

    public init(replacements: [(String, String)]) {
        self.replacements = replacements.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
    }

    public static func == (lhs: RecognitionDictionary, rhs: RecognitionDictionary) -> Bool {
        lhs.replacements.elementsEqual(rhs.replacements) { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// Compiled-JSON (v1) on-disk shape: `{"version":1,"replacements":[["variant","Canonical"], ...],"bias":["Term", ...]}`.
    /// `bias` is decoded when present but is not used on the 4A hot path.
    private struct CompiledDictionaryDTO: Codable {
        let version: Int
        let replacements: [[String]]
        let bias: [String]?
    }

    /// Loads and decodes a compiled-JSON dictionary from `url`. Throws on missing/unreadable/
    /// malformed JSON so the caller can fall back to `.empty`. A replacement row without exactly
    /// 2 elements is skipped rather than failing the whole load.
    public static func load(contentsOf url: URL) throws -> RecognitionDictionary {
        let data = try Data(contentsOf: url)
        let dto = try JSONDecoder().decode(CompiledDictionaryDTO.self, from: data)
        let pairs = dto.replacements.compactMap { row -> (String, String)? in
            // Skip malformed rows, empty variants (an empty variant compiles to a zero-width
            // regex that would match every word boundary), and empty canonicals.
            guard row.count == 2, !row[0].isEmpty, !row[1].isEmpty else { return nil }
            return (row[0], row[1])
        }
        return RecognitionDictionary(replacements: pairs)
    }

    /// Applies replacements in a SINGLE leftmost-longest pass over the ORIGINAL text: an inserted
    /// canonical is never rescanned (so a canonical containing another variant is left intact).
    /// Whole-"token" match = not adjacent to a word char (`(?<!\w)`…`(?!\w)`), case-insensitive.
    /// Variants and input are NFC-normalized (ICU does no canonical-equivalence matching). A variant
    /// whose regex fails to compile is logged and skipped, never disabling the rest of the dictionary.
    public func apply(_ text: String) -> String {
        guard !replacements.isEmpty else { return text }
        let haystack = text.precomposedStringWithCanonicalMapping   // NFC
        let ns = haystack as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Collect every candidate match from every variant over the ORIGINAL text.
        struct Candidate { let range: NSRange; let canonical: String; let scalarLen: Int; let order: Int }
        var candidates: [Candidate] = []
        // Deterministic order for tie-breaks: pairs are already sorted in init(); index is stable.
        for (order, pair) in replacements.enumerated() {
            let variant = pair.0.precomposedStringWithCanonicalMapping
            let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: variant) + "(?!\\w)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                FileHandle.standardError.write(Data("[dictionary] skipped uncompilable variant: \(variant)\n".utf8))
                continue
            }
            let scalarLen = variant.unicodeScalars.count
            regex.enumerateMatches(in: haystack, options: [], range: full) { m, _, _ in
                if let r = m?.range, r.length > 0 {
                    candidates.append(Candidate(range: r, canonical: pair.1, scalarLen: scalarLen, order: order))
                }
            }
        }
        if candidates.isEmpty { return haystack }

        // Leftmost-longest with deterministic tie-break: sort by start asc, then longer match first,
        // then by input order. Then greedily accept non-overlapping matches left to right.
        candidates.sort { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length > b.range.length }
            if a.scalarLen != b.scalarLen { return a.scalarLen > b.scalarLen }
            return a.order < b.order
        }
        var chosen: [Candidate] = []
        var cursor = 0
        for c in candidates where c.range.location >= cursor {
            chosen.append(c)
            cursor = c.range.location + c.range.length
        }

        // Apply right-to-left so earlier ranges stay valid.
        let result = NSMutableString(string: haystack)
        for c in chosen.reversed() {
            result.replaceCharacters(in: c.range, with: c.canonical)
        }
        return result as String
    }
}
