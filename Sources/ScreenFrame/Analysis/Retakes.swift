import AVFoundation

/// "Take again": when the hotkey is pressed, the sentence you were just saying is cut. The voice
/// level finds it: the latest real pause clearly before the press marks where it began.
enum Retakes {
    static func cuts(for info: RecordingInfo, folder: URL) async -> [ClosedRange<Double>] {
        guard let marks = info.retakeMarks, !marks.isEmpty else { return [] }
        let track = info.audio.first { $0.kind == "microphone" } ?? info.audio.first
        var peaks: [Float] = []
        if let track { peaks = await Waveform.peaks(of: folder.appendingPathComponent(track.file)) }
        let perSecond = Double(Waveform.perSecond)
        guard let track, peaks.count > 10 else {
            return marks.map { max(0, $0 - 3)...$0 }
        }
        let sorted = peaks.sorted()
        let floor = Double(sorted[sorted.count / 5]), loud = Double(sorted[sorted.count * 9 / 10])
        let threshold = max(0.03, floor + 0.2 * (loud - floor))
        func speaking(_ t: Double) -> Bool {
            let i = Int((t - track.offset) * perSecond)
            return i >= 0 && i < peaks.count && Double(peaks[i]) >= threshold
        }
        // Silent stretches (start, end) in video time.
        var pauses: [(Double, Double)] = []
        var runStart: Double?
        var t = track.offset
        let end = track.offset + Double(peaks.count) / perSecond
        while t < end {
            if !speaking(t) { if runStart == nil { runStart = t } } else if let start = runStart {
                pauses.append((start, t))
                runStart = nil
            }
            t += 0.02
        }
        let language = UserDefaults.standard.string(forKey: "captionLanguage") ?? "de-DE"
        var result: [ClosedRange<Double>] = []
        for mark in marks {
            if let start = await sentenceStart(before: mark, file: folder.appendingPathComponent(track.file),
                                               offset: track.offset, language: language) {
                result.append(max(0, start - 0.1)...(mark + 0.2))
                continue
            }
            result.append(fromPauses(mark))
        }
        return result

        func fromPauses(_ mark: Double) -> ClosedRange<Double> {
            // The sentence starts after the latest real pause that is clearly before the key press
            // (pauses right before the press are the botch itself, or breaths inside the sentence).
            let window = pauses.filter { $0.1 <= mark - 1.2 && $0.1 >= mark - 12 }
            let start = window.last(where: { $0.1 - $0.0 >= 0.3 })?.1
                ?? window.last(where: { $0.1 - $0.0 >= 0.2 })?.1
                ?? max(0, mark - 4)
            return max(0, start - 0.05)...(mark + 0.2)
        }
    }

    /// Transcribes the 15 s before the press (on-device) and returns where the last sentence began,
    /// in video time: the word after the last sentence end that is clearly before the press.
    private static func sentenceStart(before mark: Double, file: URL, offset: Double, language: String) async -> Double? {
        let chunkStart = max(0, mark - offset - 15), length = min(15, mark - offset)
        guard length > 1 else { return nil }
        let chunk = FileManager.default.temporaryDirectory.appendingPathComponent("screenframe-retake-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: chunk) }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: file), presetName: AVAssetExportPresetAppleM4A) else { return nil }
        session.timeRange = CMTimeRange(start: CMTime(seconds: chunkStart, preferredTimescale: 600),
                                        duration: CMTime(seconds: length, preferredTimescale: 600))
        guard (try? await session.export(to: chunk, as: .m4a)) != nil,
              let words = try? await Captioner.words(in: chunk, language: language, progress: { _ in }), !words.isEmpty else { return nil }
        let base = chunkStart + offset
        let spoken = words.filter { base + $0.end <= mark + 0.3 }
        guard !spoken.isEmpty else { return nil }
        // The botched sentence needs at least one word; its start follows the previous sentence end.
        let ends = spoken.indices.filter { i in
            i < spoken.count - 1 && spoken[i].text.last.map { ".?!".contains($0) } == true && base + spoken[i].end < mark - 0.4
        }
        var first = ends.last.map { $0 + 1 } ?? 0
        // A missed full stop makes the "sentence" too long: then start after the biggest pause
        // between words in it instead (sentences rarely run past 7 s).
        if mark - (base + spoken[first].start) > 7 {
            let candidates = (first + 1)..<spoken.count
            if let gap = candidates.filter({ base + spoken[$0].start < mark - 1.2 })
                .max(by: { spoken[$0].start - spoken[$0 - 1].end < spoken[$1].start - spoken[$1 - 1].end }),
               spoken[gap].start - spoken[gap - 1].end >= 0.12 {
                first = gap
            }
        }
        return base + spoken[first].start
    }
}
