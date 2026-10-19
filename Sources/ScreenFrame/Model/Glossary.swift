import Foundation

/// Brand names and terms the speech recognizer gets wrong. Used three ways: as vocabulary hints
/// for recognition, to correct every new transcript automatically, and on demand for existing
/// subtitles. Stored app-wide in Application Support/ScreenFrame/glossary.json.
struct GlossaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// How it should be written.
    var term: String
    /// What the recognizer hears instead (the term itself in any casing is always fixed too).
    var variants: [String] = []
}

enum Glossary {
    private static var file: URL { BrandKitStore.folder.appendingPathComponent("glossary.json") }

    static func load() -> [GlossaryEntry] {
        if let data = try? Data(contentsOf: file), let entries = try? JSONDecoder().decode([GlossaryEntry].self, from: data) {
            return entries
        }
        let defaults = [
            GlossaryEntry(term: "snipKI", variants: ["snip KI", "Snip KI", "snippet KI", "Schnipp KI", "snipkey", "Snap K E",
                                                     "Snap KI", "Snip K E", "snip K I", "Snipe KI"]),
            GlossaryEntry(term: "ScreenFrame", variants: ["Screen Free", "Screen Frame", "Screenframe"]),
            GlossaryEntry(term: "Claude", variants: ["Claud", "Klot"]),
            GlossaryEntry(term: "Claude Code", variants: ["Cloud Code", "Clod Code"]),
            GlossaryEntry(term: "KI-Update", variants: ["KI Update", "Kai Update", "K Update", "K I Update", "Ka I Update"]),
            GlossaryEntry(term: "Jens Polomski", variants: ["Jens Polomsky", "Jens Polonski"]),
        ]
        save(defaults)
        return defaults
    }

    static func save(_ entries: [GlossaryEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(entries).write(to: file, options: .atomic)
    }

    /// Vocabulary hints for the recognizer.
    static var terms: [String] { load().map(\.term).filter { !$0.isEmpty } }

    /// Fixes a text: every variant (and the term in other casing) becomes the term. Whole words only.
    static func fix(_ text: String, entries: [GlossaryEntry] = load()) -> String {
        var result = text
        for entry in entries where !entry.term.isEmpty {
            for variant in Set(entry.variants + [entry.term]) where !variant.isEmpty {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: variant)
                    .replacingOccurrences(of: "\\ ", with: "\\s+") + "(?![\\p{L}\\p{N}])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                        withTemplate: NSRegularExpression.escapedTemplate(for: entry.term))
            }
        }
        return result
    }

    /// The same for timed words: a variant spanning several words ("Screen Free") becomes one word
    /// covering their time, keeping the last word's punctuation. Compared as phrases, because the
    /// recognizer sometimes returns spelled letters as one word ("SNAP K E.").
    static func fix(_ words: [Captioner.Word], entries: [GlossaryEntry] = load()) -> [Captioner.Word] {
        func bare(_ s: String) -> String {
            s.lowercased().split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let rules = entries.filter { !$0.term.isEmpty }.flatMap { entry in
            Set(entry.variants + [entry.term]).map { (phrase: bare($0), term: entry.term) }
        }
        .filter { !$0.phrase.isEmpty }
        let byPhrase = Dictionary(rules.map { ($0.phrase, $0.term) }, uniquingKeysWith: { first, _ in first })
        let longest = rules.map { $0.phrase.split(separator: " ").count }.max() ?? 1

        var result: [Captioner.Word] = []
        var i = 0
        while i < words.count {
            var matched = false
            // Longest span first, so "Claude Code" wins over "Claude".
            for length in stride(from: min(longest, words.count - i), through: 1, by: -1) {
                let slice = words[i..<(i + length)]
                guard let term = byPhrase[slice.map { bare($0.text) }.joined(separator: " ")] else { continue }
                let last = slice.last!.text
                let trailing = String(last.reversed().prefix { $0.isPunctuation }.reversed())
                result.append(Captioner.Word(text: term + trailing, start: slice.first!.start, end: slice.last!.end))
                i += length
                matched = true
                break
            }
            if !matched {
                result.append(words[i])
                i += 1
            }
        }
        return result
    }

    /// Corrections worth remembering from a proofread line: spans of the old text that were
    /// replaced by a glossary term ("Snap K E" → "snipKI"), via a word-level diff.
    static func learnedVariants(old: String, new: String, terms: [String]) -> [(heard: String, term: String)] {
        func tokens(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
        func bare(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let a = tokens(old), b = tokens(new)
        // Longest common subsequence on bare tokens.
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = bare(a[i]) == bare(b[j]) ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var pairs: [(String, String)] = []
        var i = 0, j = 0
        var oldSpan: [String] = [], newSpan: [String] = []
        func flush() {
            defer { oldSpan = []; newSpan = [] }
            guard !oldSpan.isEmpty, !newSpan.isEmpty else { return }
            let replaced = newSpan.map(bare).joined(separator: " ")
            for term in terms where bare(term) == replaced || term.lowercased() == replaced {
                pairs.append((oldSpan.map { $0.trimmingCharacters(in: .punctuationCharacters) }.joined(separator: " "), term))
            }
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, bare(a[i]) == bare(b[j]) {
                flush()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                newSpan.append(b[j])
                j += 1
            } else {
                oldSpan.append(a[i])
                i += 1
            }
        }
        flush()
        return pairs.filter { $0.0.caseInsensitiveCompare($0.1) != .orderedSame && !$0.0.isEmpty }
    }
}
