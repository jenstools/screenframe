import AppKit

/// Correcting subtitles in one go: find & replace, the brand glossary, a Claude pass, merging and
/// styling all captions at once.
extension EditorModel {
    var sortedCaptions: [TextOverlay] { captions.sorted { $0.start < $1.start } }

    private func regex(_ find: String, caseSensitive: Bool, wholeWord: Bool) -> NSRegularExpression? {
        guard !find.isEmpty else { return nil }
        var pattern = NSRegularExpression.escapedPattern(for: find)
        if wholeWord { pattern = "(?<![\\p{L}\\p{N}])" + pattern + "(?![\\p{L}\\p{N}])" }
        return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : .caseInsensitive)
    }

    func matchCount(_ find: String, caseSensitive: Bool, wholeWord: Bool) -> Int {
        guard let regex = regex(find, caseSensitive: caseSensitive, wholeWord: wholeWord) else { return 0 }
        return captions.reduce(0) { $0 + regex.numberOfMatches(in: $1.text, range: NSRange($1.text.startIndex..., in: $1.text)) }
    }

    /// Replaces in every subtitle at once (one undo step). Returns the number of replacements.
    @discardableResult
    func replaceAll(_ find: String, with replacement: String, caseSensitive: Bool, wholeWord: Bool) -> Int {
        guard let regex = regex(find, caseSensitive: caseSensitive, wholeWord: wholeWord) else { return 0 }
        var count = 0
        var updated = texts
        for i in updated.indices where updated[i].caption {
            let text = updated[i].text
            let range = NSRange(text.startIndex..., in: text)
            let n = regex.numberOfMatches(in: text, range: range)
            guard n > 0 else { continue }
            count += n
            updated[i].text = regex.stringByReplacingMatches(in: text, range: range,
                                                             withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        if count > 0 { texts = updated }
        show(count == 0 ? "No matches" : "Replaced \(count)×")
        return count
    }

    func saveGlossary() { Glossary.save(glossary) }

    /// Applies the glossary to all subtitles and the cached transcript.
    func applyGlossary() {
        saveGlossary()
        var changed = 0
        var updated = texts
        for i in updated.indices where updated[i].caption {
            let fixed = Glossary.fix(updated[i].text, entries: glossary)
            if fixed != updated[i].text {
                updated[i].text = fixed
                changed += 1
            }
        }
        if changed > 0 { texts = updated }
        for (path, words) in wordsByFile { wordsByFile[path] = Glossary.fix(words, entries: glossary) }
        objectWillChange.send()
        show(changed == 0 ? "Glossary: nothing to fix" : "Glossary fixed \(changed) subtitles")
    }

    /// Adds a glossary entry from a correction ("they said X, it should be Y") and applies it.
    func learn(_ heard: String, as term: String) {
        let heard = heard.trimmingCharacters(in: .whitespaces), term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        if let i = glossary.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
            if !heard.isEmpty, !glossary[i].variants.contains(heard) { glossary[i].variants.append(heard) }
        } else {
            glossary.append(GlossaryEntry(term: term, variants: heard.isEmpty ? [] : [heard]))
        }
        applyGlossary()
    }

    /// Claude corrects misheard words (brand names first), spelling and punctuation, keeping
    /// wording and line count. Changed lines are marked for review; one undo reverts all.
    func fixSubtitlesWithClaude() {
        let lines = sortedCaptions
        guard !lines.isEmpty, begin("subfix", "Claude is checking \(lines.count) subtitles…") else { return }
        let glossary = self.glossary, name = self.name, language = captionLanguage
        Task {
            defer { end("subfix") }
            var fixes: [UUID: String] = [:]
            do {
                let chunks = stride(from: 0, to: lines.count, by: 120).map { Array(lines[$0..<min($0 + 120, lines.count)]) }
                for (n, chunk) in chunks.enumerated() {
                    report("subfix", progress: Double(n) / Double(chunks.count))
                    let system = """
                    You proofread video subtitles produced by speech recognition (language: \(language)). Fix ONLY: misheard \
                    words (especially brand names, product names, people and technical terms), spelling, capitalisation and \
                    punctuation. Never rephrase, shorten, translate or add content. Keep exactly the same number of lines in \
                    the same order. Use these correct spellings when the audio clearly meant them:
                    \(glossary.map { "- \($0.term)" + ($0.variants.isEmpty ? "" : " (often misheard as: \($0.variants.joined(separator: ", ")))") }.joined(separator: "\n"))
                    Answer with ONLY JSON: {"lines": ["line 1", "line 2", ...]}
                    """
                    let prompt = "Video: \(name)\n" + chunk.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
                    let json = try AIClient.json(in: try await AIClient.ask(system: system, prompt: prompt))
                    let fixed = json["lines"] as? [String] ?? []
                    guard fixed.count == chunk.count else { continue }   // never misalign lines
                    for (line, text) in zip(chunk, fixed) {
                        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty, clean != line.text { fixes[line.id] = clean }
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            guard !fixes.isEmpty else {
                show("Claude found nothing to fix")
                return
            }
            var updated = texts
            var originals: [UUID: String] = [:]
            for i in updated.indices {
                if let text = fixes[updated[i].id] {
                    originals[updated[i].id] = updated[i].text
                    updated[i].text = text
                }
            }
            texts = updated
            fixOriginals = originals
            recentlyFixed = Set(fixes.keys)
            show("Claude fixed \(fixes.count) subtitles (marked ✦, ⌘Z to undo)")
        }
    }

    /// Brand-name corrections Claude made that the glossary doesn't know yet.
    var learnableFixes: [(heard: String, term: String)] {
        let terms = glossary.map(\.term).filter { !$0.isEmpty }
        var seen = Set<String>()
        return texts.filter { fixOriginals[$0.id] != nil }.flatMap { line in
            Glossary.learnedVariants(old: fixOriginals[line.id]!, new: line.text, terms: terms)
        }
        .filter { pair in
            let known = glossary.first { $0.term == pair.term }?.variants.contains { $0.caseInsensitiveCompare(pair.heard) == .orderedSame } ?? false
            return !known && seen.insert(pair.heard.lowercased() + "→" + pair.term).inserted
        }
    }

    /// Adds those corrections to the glossary, so the next transcription gets them right.
    func learnFromFixes() {
        let pairs = learnableFixes
        guard !pairs.isEmpty else { show("Nothing new to learn"); return }
        for pair in pairs {
            if let i = glossary.firstIndex(where: { $0.term == pair.term }) { glossary[i].variants.append(pair.heard) }
        }
        saveGlossary()
        show("Learned \(pairs.count) correction\(pairs.count == 1 ? "" : "s"): " + pairs.map { "\($0.heard) → \($0.term)" }.joined(separator: ", "))
    }

    func mergeCaptionWithNext(_ id: UUID) {
        let sorted = sortedCaptions
        guard let i = sorted.firstIndex(where: { $0.id == id }), i + 1 < sorted.count else { return }
        let next = sorted[i + 1]
        var updated = texts
        guard let a = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[a].text = (updated[a].text + " " + next.text).trimmingCharacters(in: .whitespaces)
        updated[a].end = next.end
        updated.removeAll { $0.id == next.id }
        texts = updated
    }

    func deleteCaption(_ id: UUID) {
        texts.removeAll { $0.id == id }
    }

    func playCaption(_ caption: TextOverlay) {
        seek(to: caption.start)
        if player.rate == 0 { togglePlay() }
    }

    /// One look for every subtitle.
    /// The look for all subtitles: the saved one, else the first caption's (older projects), else
    /// the default.
    var captionStyle: CaptionStyle {
        settings.captionStyle ?? sortedCaptions.first.map(CaptionStyle.init) ?? CaptionStyle()
    }

    /// Changes the look of every subtitle and remembers it for generated ones. Only the changed
    /// properties are applied, so per-line tweaks of the others stay.
    func styleAllCaptions(_ change: (inout CaptionStyle) -> Void) {
        let old = captionStyle
        var style = old
        change(&style)
        guard style != old || settings.captionStyle == nil else { return }
        settings.captionStyle = style
        var updated = texts
        for i in updated.indices where updated[i].caption { style.apply(to: &updated[i], changedFrom: old) }
        texts = updated
    }

    /// Gives every subtitle the complete look of one of them.
    func applyCaptionStyle(from id: UUID) {
        guard let line = texts.first(where: { $0.id == id }) else { return }
        let style = CaptionStyle(line)
        settings.captionStyle = style
        var updated = texts
        for i in updated.indices where updated[i].caption { style.apply(to: &updated[i]) }
        texts = updated
        show("Style applied to \(captions.count) subtitles")
    }
}
