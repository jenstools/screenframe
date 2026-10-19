import AVFoundation
import Speech

/// Speech → timed words with Apple's recognizer (on-device when the language supports it), then
/// words → caption lines.
enum Captioner {
    struct Word {
        let text: String
        let start: Double
        let end: Double
    }

    enum CaptionError: LocalizedError {
        case denied
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "Speech recognition isn't allowed. Enable it in System Settings › Privacy & Security › Speech Recognition."
            case .unavailable(let language): return "Speech recognition for \(language) isn't available on this Mac."
            }
        }
    }

    static let languages: [(id: String, name: String)] = [("de-DE", "Deutsch"), ("en-US", "English"), ("en-GB", "English (UK)"),
                                                          ("fr-FR", "Français"), ("es-ES", "Español"), ("it-IT", "Italiano")]

    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Words of an audio (or video) file, in file time. The audio is read as 16 kHz mono,
    /// split at quiet points into chunks under a minute (server recognition's limit; on-device
    /// has none but stays fast), and every chunk is level-normalized first: quiet microphones
    /// otherwise come back almost empty.
    static func words(in url: URL, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        guard await authorize() else { throw CaptionError.denied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw CaptionError.unavailable(language)
        }
        let rate = 16_000.0
        let samples = try await loadMono(url, sampleRate: rate)
        guard samples.count > Int(rate * 0.3) else { return [] }

        var words: [Word] = []
        var start = 0
        var failures = 0
        while start < samples.count {
            let end = chunkEnd(samples, from: start, rate: rate)
            let chunk = normalized(Array(samples[start..<end]))
            let offset = Double(start) / rate
            var result: SFSpeechRecognitionResult?
            for attempt in 0..<2 where result == nil {
                do {
                    result = try await recognize(chunk, rate: rate, with: recognizer)
                } catch {
                    // "No speech detected" is just silence; anything else gets one retry.
                    if (error as NSError).code == 1110 { break }
                    if attempt == 1 { failures += 1 }
                }
            }
            if let result {
                words += result.bestTranscription.segments
                    .filter { !$0.substring.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { Word(text: $0.substring, start: offset + $0.timestamp, end: offset + $0.timestamp + $0.duration) }
            }
            start = end
            progress(min(1, Double(start) / Double(samples.count)))
        }
        // The recognizer sometimes returns several words as one segment ("beim K. Update"): split
        // them (time shared by length) so editing and the glossary work word by word.
        words = words.flatMap { word -> [Word] in
            let parts = word.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count > 1 else { return [word] }
            let total = Double(parts.reduce(0) { $0 + $1.count })
            var t = word.start
            return parts.map { part in
                let length = (word.end - word.start) * Double(part.count) / total
                defer { t += length }
                return Word(text: part, start: t, end: t + length)
            }
        }
        // Brand names and terms from the glossary, written the way they should be.
        words = Glossary.fix(words)
        if words.isEmpty, failures > 0 {
            throw NSError(domain: "ScreenFrame", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "Speech recognition failed. If this language isn't downloaded for on-device dictation, turn on Dictation in System Settings › Keyboard."])
        }
        return words
    }

    /// Mono Float32 samples at `sampleRate` from any audio or video file.
    static func loadMono(_ url: URL, sampleRate: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: sampleRate,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4)) }
        }
        return samples
    }

    /// Next chunk end: around 50 s, at the quietest half second between 40 and 55 s.
    private static func chunkEnd(_ samples: [Float], from start: Int, rate: Double) -> Int {
        let maxEnd = start + Int(55 * rate)
        guard maxEnd < samples.count else { return samples.count }
        let window = Int(0.5 * rate)
        var best = start + Int(50 * rate), quietest = Float.infinity
        var position = start + Int(40 * rate)
        while position + window < maxEnd {
            var energy: Float = 0
            for i in stride(from: position, to: position + window, by: 8) { energy += abs(samples[i]) }
            if energy < quietest { quietest = energy; best = position + window / 2 }
            position += window / 2
        }
        return best
    }

    /// Peak-normalizes (robust to clicks) to about −3 dB, with at most +30 dB of gain.
    private static func normalized(_ chunk: [Float]) -> [Float] {
        let magnitudes = chunk.enumerated().compactMap { $0.offset % 16 == 0 ? abs($0.element) : nil }.sorted()
        guard let peak = magnitudes.isEmpty ? nil : magnitudes[min(magnitudes.count - 1, Int(Double(magnitudes.count) * 0.999))],
              peak > 0.0005 else { return chunk }
        let gain = min(31.6, 0.7 / peak)
        guard gain > 1.05 else { return chunk }
        return chunk.map { max(-1, min(1, $0 * gain)) }
    }

    private static func recognize(_ samples: [Float], rate: Double, with recognizer: SFSpeechRecognizer) async throws -> SFSpeechRecognitionResult {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // Vocabulary hints: brand names the recognizer wouldn't know.
        request.contextualStrings = Array(Glossary.terms.prefix(100))
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let step = Int(rate)  // one-second buffers
        var index = 0
        while index < samples.count {
            let count = min(step, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + index, count: count)
            }
            request.append(buffer)
            index += count
        }
        request.endAudio()
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Groups words into subtitle lines: at most ~42 characters and 3.5 s, broken at pauses and
    /// sentence ends.
    static func lines(from words: [Word]) -> [Word] {
        var lines: [Word] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(Word(text: current.map(\.text).joined(separator: " "), start: first.start, end: last.end))
            current.removeAll()
        }
        for word in words {
            if let last = current.last, let first = current.first {
                let length = current.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
                let sentenceEnd = last.text.last.map { ".?!".contains($0) } ?? false
                if length > 42 || word.start - last.end > 0.7 || word.end - first.start > 3.5 || sentenceEnd { flush() }
            }
            current.append(word)
        }
        flush()
        // Hold each line a little longer, but never into the next one.
        return lines.enumerated().map { i, line in
            let next = i + 1 < lines.count ? lines[i + 1].start : .infinity
            return Word(text: line.text, start: line.start, end: min(next - 0.05, max(line.end + 0.3, line.start + 0.9)))
        }
    }
}
