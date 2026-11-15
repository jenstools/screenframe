import Foundation

/// Picks several shorts from one video: Claude reads the transcript and returns stretches that work
/// on their own, each with a hook, a YouTube title, a description and hashtags. Without Claude (or
/// when its answer is unusable) the stretches with the most speech are taken instead.
enum ShortsPlanner {
    struct Plan {
        var hook: String
        var title: String
        var description: String
        var hashtags: [String]
        /// Timeline stretches of the original, in order.
        var ranges: [ClosedRange<Double>]
        var duration: Double { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
    }

    enum Length: String, CaseIterable, Identifiable {
        case quick, standard, long
        var id: String { rawValue }
        var label: String {
            switch self {
            case .quick: return "15–30 s"
            case .standard: return "30–60 s"
            case .long: return "1–3 min"
            }
        }
        var seconds: ClosedRange<Double> {
            switch self {
            case .quick: return 15...30
            case .standard: return 30...60
            case .long: return 60...180
            }
        }
    }

    /// About one short per 2.5 minutes of video, 1…5.
    static func autoCount(duration: Double) -> Int { max(1, min(5, Int((duration / 150).rounded()))) }

    static let systemPrompt = """
    You cut YouTube Shorts out of a longer screen recording. From the transcript, pick stretches that \
    each work entirely on their own: a strong hook in the first 2 seconds (a claim, a question, a \
    surprising result), one idea, a natural ending; no references to "as I said before". A short may \
    join up to 3 stretches if that makes a tighter story. Shorts must not overlap each other or the \
    already existing shorts. Start and end on sentence boundaries from the transcript times. \
    Write everything in the language of the transcript. For each short give:
    - hook: on-screen title for the first seconds, max 6 words
    - title: YouTube title, max 70 characters, curiosity without clickbait
    - description: 1–3 short sentences for the YouTube description
    - hashtags: 3–5 relevant hashtags without "#" (no "Shorts", it is added automatically)
    If the transcript has fewer good moments, return fewer shorts; if none, return an empty list and \
    a one-sentence "error" saying why. \
    Answer with ONLY JSON: {"shorts": [{"hook": "...", "title": "...", "description": "...", \
    "hashtags": ["..."], "ranges": [{"start": s, "end": s}]}], "error": null}
    """

    static func prompt(lines: [Captioner.Word], duration: Double, count: Int, length: Length,
                       existing: [ClosedRange<Double>]) -> String {
        var text = "Duration: \(Int(duration)) s\n"
        text += "Make \(count) short\(count == 1 ? "" : "s"), each \(Int(length.seconds.lowerBound))–\(Int(length.seconds.upperBound)) seconds in total.\n"
        if !existing.isEmpty {
            text += "Already existing shorts (do not reuse): "
                + existing.map { String(format: "%.1f–%.1f", $0.lowerBound, $0.upperBound) }.joined(separator: ", ") + "\n"
        }
        text += "Transcript (timeline seconds):\n"
        text += lines.map { String(format: "[%.1f–%.1f] %@", $0.start, $0.end, $0.text) }.joined(separator: "\n")
        return text
    }

    /// Valid plans from Claude's JSON: ranges clamped to the video, too short/long or overlapping
    /// ones dropped.
    static func parse(_ json: [String: Any], duration: Double, length: Length,
                      existing: [ClosedRange<Double>]) -> [Plan] {
        let items = json["shorts"] as? [[String: Any]] ?? []
        var taken = existing
        var plans: [Plan] = []
        for item in items {
            let ranges = (item["ranges"] as? [[String: Any]] ?? []).compactMap { r -> ClosedRange<Double>? in
                guard let a = AIEditor.number(r["start"]), let b = AIEditor.number(r["end"]) else { return nil }
                let lo = max(0, a), hi = min(duration, b)
                return hi > lo + 0.5 ? lo...hi : nil
            }
            let merged = EditOps.merge(ranges)
            let total = merged.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            // Some slack: Claude's sums are approximate and a sentence may run over.
            guard !merged.isEmpty, total >= length.seconds.lowerBound * 0.6, total <= length.seconds.upperBound * 1.25 else { continue }
            guard !merged.contains(where: { r in taken.contains { overlap(r, $0) > 0.3 * (r.upperBound - r.lowerBound) } }) else { continue }
            taken += merged
            plans.append(Plan(hook: string(item["hook"]), title: String(string(item["title"]).prefix(ShortInfo.titleLimit)),
                              description: string(item["description"]),
                              hashtags: (item["hashtags"] as? [Any] ?? []).compactMap { $0 as? String }
                                  .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.filter { !$0.isEmpty },
                              ranges: merged))
        }
        return plans
    }

    /// Without Claude: the windows with the most speech, not overlapping each other or existing shorts.
    static func fallback(lines: [Captioner.Word], duration: Double, count: Int, length: Length,
                         existing: [ClosedRange<Double>]) -> [Plan] {
        let window = min(duration, (length.seconds.lowerBound + length.seconds.upperBound) / 2)
        guard window > 1 else { return [] }
        var taken = existing
        var plans: [Plan] = []
        for n in 0..<count {
            var best: (start: Double, speech: Double)?
            var start = 0.0
            while start + window <= duration + 0.001 {
                let r = start...(start + window)
                if !taken.contains(where: { overlap(r, $0) > 0 }) {
                    let speech = lines.reduce(0) { $0 + max(0, min($1.end, r.upperBound) - max($1.start, r.lowerBound)) }
                    if speech > (best?.speech ?? -1) { best = (start, speech) }
                }
                start += 1
            }
            guard let best else { break }
            let range = best.start...(best.start + window)
            taken.append(range)
            let first = lines.first { $0.end > range.lowerBound }?.text ?? ""
            let hook = first.split(separator: " ").prefix(6).joined(separator: " ")
            plans.append(Plan(hook: hook, title: hook.isEmpty ? "Short \(n + 1)" : hook, description: "", hashtags: [],
                              ranges: [range]))
        }
        return plans.sorted { $0.ranges[0].lowerBound < $1.ranges[0].lowerBound }
    }

    private static func overlap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
