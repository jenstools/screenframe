import Foundation

/// A proposed cut, in timeline time, shown on the timeline before it's applied.
struct CutSuggestion: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var reason: String
}

/// Finds silences (from the voice level) and filler words (from the transcript).
enum Cleanup {
    static let fillerWords: Set<String> = ["äh", "ähm", "öh", "öhm", "ehm", "hm", "hmm", "mhm", "uh", "uhm", "um", "umm", "er", "erm"]

    /// The track that carries the speaker: microphone, else a video file's own audio.
    static func voiceTrack(of p: ClipPlacement) -> AudioTrackInfo? {
        p.media.info.audio.first { $0.kind == "microphone" } ?? p.media.info.audio.first { $0.kind == "clip-audio" }
    }

    /// Pauses of at least `minimum` seconds. With `keepActivity`, pauses where you click, type or
    /// move the mouse are kept: those are silent demos, not dead air.
    static func silences(in placements: [ClipPlacement], waveforms: [String: [Float]], keepActivity: Bool,
                         minimum: Double = 0.9) -> [CutSuggestion] {
        var result: [CutSuggestion] = []
        for p in placements {
            guard let track = voiceTrack(of: p),
                  let peaks = waveforms[p.media.folder.appendingPathComponent(track.file).path], peaks.count > 10 else { continue }
            let sorted = peaks.sorted()
            let floor = Double(sorted[sorted.count / 5]), loud = Double(sorted[sorted.count * 9 / 10])
            let threshold = max(0.03, floor + 0.2 * (loud - floor))
            let perSecond = Double(Waveform.perSecond)
            let lo = p.offset + p.overlapIn, hi = p.end - p.overlapOut
            var runStart: Double?
            var t = lo
            func close(at end: Double) {
                guard let start = runStart else { return }
                runStart = nil
                guard end - start >= minimum else { return }
                // Keep a little breath on both sides.
                let a = start + 0.25, b = end - 0.25
                guard b - a >= 0.35 else { return }
                if keepActivity, hasActivity(p, from: p.sourceTime(a), to: p.sourceTime(b)) { return }
                result.append(CutSuggestion(start: a, end: b, reason: "Silence \(String(format: "%.1f", b - a)) s"))
            }
            while t < hi {
                let i = Int((p.sourceTime(t) - track.offset) * perSecond)
                let quiet = i < 0 || i >= peaks.count || Double(peaks[i]) < threshold
                if quiet { if runStart == nil { runStart = t } } else { close(at: t) }
                t += 0.02
            }
            close(at: hi)
        }
        return result
    }

    /// Filler words from the transcript ("ähm", "uh", …), if the recognizer kept them.
    static func fillers(in placements: [ClipPlacement], words: [String: [Captioner.Word]]) -> [CutSuggestion] {
        var result: [CutSuggestion] = []
        for p in placements {
            guard let track = voiceTrack(of: p) ?? p.media.info.audio.first,
                  let list = words[p.media.folder.appendingPathComponent(track.file).path] else { continue }
            for word in list {
                let token = word.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                guard fillerWords.contains(token) else { continue }
                let s0 = word.start + track.offset - 0.05, s1 = word.end + track.offset + 0.05
                guard s0 >= p.clip.start, s1 <= p.clip.end else { continue }
                result.append(CutSuggestion(start: p.timelineTime(s0), end: p.timelineTime(s1), reason: "“\(word.text)”"))
            }
        }
        return result
    }

    private static func hasActivity(_ p: ClipPlacement, from s0: Double, to s1: Double) -> Bool {
        let info = p.media.info
        if info.clicks.contains(where: { $0.t >= s0 && $0.t <= s1 }) { return true }
        if (info.keystrokes ?? []).contains(where: { $0 >= s0 && $0 <= s1 }) { return true }
        let moves = info.mouse.filter { $0.t >= s0 && $0.t <= s1 }
        var distance = 0.0
        for (a, b) in zip(moves, moves.dropFirst()) { distance += hypot(b.x - a.x, b.y - a.y) }
        return distance > 0.04 * hypot(info.sourceWidth, info.sourceHeight)
    }
}
