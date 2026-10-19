import AVFoundation
import AppKit

/// Camera keyframes, smart camera, cleanup, privacy blur, prompt editing and shorts.
extension EditorModel {
    // MARK: Camera lane

    var selectedCameraKey: CameraKey? {
        guard case .cameraKey(let id) = selection else { return nil }
        return cameraKeys.first { $0.id == id }
    }

    /// Layout in effect at the playhead (from the keyframes, else the clip).
    var currentCameraLayout: Clip.CameraLayout {
        cameraKeys.filter { $0.t <= currentTime }.max(by: { $0.t < $1.t })?.layout ?? placement(at: currentTime)?.clip.camera ?? .overlay
    }

    /// Bubble centre at the playhead, normalized to the output (top-left origin).
    var currentCameraCenter: CGPoint {
        guard let rect = cameraBubbleRect ?? lastBubbleRect, canvasSize.width > 0 else {
            return CGPoint(x: settings.cameraX ?? 0.85, y: settings.cameraY ?? 0.8)
        }
        return CGPoint(x: rect.midX / canvasSize.width, y: 1 - rect.midY / canvasSize.height)
    }

    private var lastBubbleRect: CGRect? {
        guard let p = placement(at: currentTime), p.media.info.webcam != nil else { return nil }
        let videoRect = RenderModel.videoRect(canvas: canvasSize, source: p.media.sourceSize, settings: settings)
        return RenderModel.CameraPlacement(settings: settings, info: p.media.info, canvas: canvasSize, videoRect: videoRect,
                                           keys: cameraKeys, baseLayout: p.clip.camera)
            .state(source: p.sourceTime(currentTime), timeline: currentTime).rect
    }

    func addCameraKey(at time: Double? = nil, layout: Clip.CameraLayout? = nil) {
        let t = time ?? currentTime
        let center = currentCameraCenter
        let key = CameraKey(t: t, x: center.x, y: center.y, layout: layout ?? currentCameraLayout)
        cameraKeys.append(key)
        selection = .cameraKey(key.id)
    }

    func updateCameraKey(_ id: UUID, _ change: (inout CameraKey) -> Void) {
        guard let i = cameraKeys.firstIndex(where: { $0.id == id }) else { return }
        change(&cameraKeys[i])
        cameraKeys[i].t = min(max(0, cameraKeys[i].t), totalDuration)
        cameraKeys[i].auto = nil
    }

    func removeCameraKeys(autoOnly: Bool = false) {
        cameraKeys.removeAll { !autoOnly || $0.auto == true }
        if case .cameraKey = selection { selection = nil }
    }

    /// Full screen while talking with nothing happening on screen, bubble otherwise.
    func autoCameraLayout() {
        let generated = SmartCamera.autoLayout(placements: placements, waveforms: waveforms, position: currentCameraCenter)
        cameraKeys = cameraKeys.filter { $0.auto != true } + generated
        analysisStatus = generated.isEmpty
            ? "No stretches found where you talk without doing anything on screen."
            : "Camera goes full screen \(generated.count / 2)× while you talk without screen activity."
    }

    /// Tracks the face in each camera video once (cached), so the bubble can centre it.
    func analyzeFaces() {
        guard settings.centerFace, !isRunning("faces") else { return }
        let videos = Set(placements.compactMap { p in p.media.info.webcam.map { p.media.folder.appendingPathComponent($0.file) } })
            .filter { FaceTracker.cached(for: $0) == nil }
        guard !videos.isEmpty, begin("faces", "Finding your face in the camera…") else { return }
        Task {
            for (i, video) in videos.enumerated() {
                _ = try? await FaceTracker.track(video) { [weak self] p in
                    Task { @MainActor in self?.report("faces", progress: (Double(i) + p) / Double(videos.count)) }
                }
            }
            end("faces")
            refreshPreview()
        }
    }

    // MARK: Transcript

    /// Words for every voice track, transcribed on-device once and cached. Callers that arrive
    /// while a transcription runs wait for it instead of starting another.
    func ensureWords() async throws {
        if let running = wordsTask { try await running.value }
        let files = Set(placements.compactMap { p -> String? in
            guard let track = Cleanup.voiceTrack(of: p) ?? p.media.info.audio.first else { return nil }
            return p.media.folder.appendingPathComponent(track.file).path
        }).filter { wordsByFile[$0] == nil }.sorted()
        guard !files.isEmpty else { return }
        let language = captionLanguage
        _ = begin("words", "Transcribing voice…")
        let task = Task { @MainActor [weak self] in
            defer { self?.end("words"); self?.wordsTask = nil }
            for (i, path) in files.enumerated() {
                let words = try await Captioner.words(in: URL(fileURLWithPath: path), language: language) { [weak self] p in
                    Task { @MainActor in self?.report("words", progress: (Double(i) + p) / Double(files.count)) }
                }
                self?.wordsByFile[path] = words
            }
            self?.objectWillChange.send()
        }
        wordsTask = task
        try await task.value
    }

    /// Transcript lines in timeline time (for the AI).
    func transcriptLines() -> [Captioner.Word] {
        placements.flatMap { p -> [Captioner.Word] in
            guard let track = Cleanup.voiceTrack(of: p) ?? p.media.info.audio.first,
                  let words = wordsByFile[p.media.folder.appendingPathComponent(track.file).path] else { return [] }
            let inClip = words.compactMap { w -> Captioner.Word? in
                let s0 = w.start + track.offset, s1 = w.end + track.offset
                guard s0 >= p.clip.start, s1 <= p.clip.end + 0.2 else { return nil }
                return Captioner.Word(text: w.text, start: p.timelineTime(s0), end: min(p.end, p.timelineTime(s1)))
            }
            return Captioner.lines(from: inClip)
        }
    }

    // MARK: Cleanup

    func findSilences() {
        let found = Cleanup.silences(in: placements, waveforms: waveforms, keepActivity: keepSilentDemos)
        cutSuggestions = mergeSuggestions(cutSuggestions.filter { !$0.reason.hasPrefix("Silence") } + found)
        analysisStatus = found.isEmpty ? "No long pauses found." : "\(found.count) pauses, \(formatDuration(found.reduce(0) { $0 + $1.end - $1.start })) in total."
    }

    func findFillers() {
        guard begin("fillers", "Finding filler words…") else { return }
        Task {
            defer { end("fillers") }
            do {
                try await ensureWords()
                let found = Cleanup.fillers(in: placements, words: wordsByFile)
                cutSuggestions = mergeSuggestions(cutSuggestions.filter { $0.reason.hasPrefix("Silence") } + found)
                analysisStatus = found.isEmpty
                    ? "No filler words recognized (the recognizer often drops them; pauses usually catch the rest)."
                    : "\(found.count) filler words."
            } catch {
                analysisStatus = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func mergeSuggestions(_ list: [CutSuggestion]) -> [CutSuggestion] {
        list.sorted { $0.start < $1.start }
    }

    func applyCuts() {
        guard !cutSuggestions.isEmpty else { return }
        let removed = cutSuggestions.reduce(0) { $0 + $1.end - $1.start }
        content = EditOps.remove(cutSuggestions.map { $0.start...$0.end }, from: content, project: snapshot)
        analysisStatus = "Removed \(cutSuggestions.count) parts (\(formatDuration(removed)))."
        cutSuggestions = []
        seek(to: min(currentTime, totalDuration))
    }

    func clearCuts() { cutSuggestions = [] }

    // MARK: Privacy

    /// Scans every recording for sensitive text and faces (replaces earlier scan results, keeps
    /// manual boxes).
    func scanPrivacy() {
        var seen = Set<String>()
        let sources = placements.filter { seen.insert($0.clip.source).inserted }
        guard !sources.isEmpty, begin("privacy", "Scanning for private info…") else { return }
        Task {
            var found: [BlurRegion] = []
            for (i, p) in sources.enumerated() {
                do {
                    found += try await PrivacyScanner.scan(media: p.media, source: p.clip.source) { [weak self] value in
                        Task { @MainActor in self?.report("privacy", progress: (Double(i) + value) / Double(sources.count)) }
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            blurs = blurs.filter { $0.kind == .manual } + found
            end("privacy", found.isEmpty ? "Nothing private found" : "Blurred \(found.count) items")
            let counts = Dictionary(grouping: found, by: \.kind).map { "\($0.value.count) \($0.key.label.lowercased())" }
            analysisStatus = found.isEmpty ? "Nothing sensitive found." : "Blurred " + counts.sorted().joined(separator: ", ") + "."
        }
    }

    func blurCount(_ kind: BlurRegion.Kind) -> (enabled: Int, total: Int) {
        let list = blurs.filter { $0.kind == kind }
        return (list.filter(\.enabled).count, list.count)
    }

    func setBlurs(_ kind: BlurRegion.Kind, enabled: Bool) {
        for i in blurs.indices where blurs[i].kind == kind { blurs[i].enabled = enabled }
    }

    func addManualBlur() {
        guard let p = placement(at: currentTime) else { return }
        let s = p.sourceTime(currentTime)
        let region = BlurRegion(source: p.clip.source, kind: .manual, start: s, end: min(p.clip.end, s + 3 * p.speed),
                                x: 0.4, y: 0.4, w: 0.2, h: 0.12, label: "Blur box")
        blurs.append(region)
        selection = .blur(region.id)
    }

    func updateBlur(_ id: UUID, _ change: (inout BlurRegion) -> Void) {
        guard let i = blurs.firstIndex(where: { $0.id == id }) else { return }
        change(&blurs[i])
        blurs[i].w = min(max(blurs[i].w, 0.01), 1)
        blurs[i].h = min(max(blurs[i].h, 0.01), 1)
        blurs[i].x = min(max(blurs[i].x, 0), 1 - blurs[i].w)
        blurs[i].y = min(max(blurs[i].y, 0), 1 - blurs[i].h)
        if blurs[i].end < blurs[i].start + 0.1 { blurs[i].end = blurs[i].start + 0.1 }
    }

    /// Blur regions visible at the playhead with where they sit in the output (zoom included).
    var blurBoxes: [(region: BlurRegion, rect: CGRect)] {
        guard let p = placement(at: currentTime), let model = renderModels[p.clip.id] else { return [] }
        let s = p.sourceTime(currentTime)
        return blurs.filter { $0.source == p.clip.source && s >= $0.start && s < $0.end }.map {
            ($0, model.outputRect(forSource: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h), time: currentTime))
        }
    }

    /// Normalized source units per output pixel at the playhead.
    var sourceUnitsPerOutputPixel: CGSize? {
        guard let p = placement(at: currentTime), let model = renderModels[p.clip.id] else { return nil }
        let scale = model.outputScale(time: currentTime)
        return CGSize(width: 1 / max(1, scale.width), height: 1 / max(1, scale.height))
    }

    var selectedBlur: BlurRegion? {
        guard case .blur(let id) = selection else { return nil }
        return blurs.first { $0.id == id }
    }

    /// Timeline spans of a blur region (it can show in several clips that use the same media).
    func timelineSpans(of region: BlurRegion) -> [ClosedRange<Double>] {
        placements.compactMap { p in
            guard p.clip.source == region.source else { return nil }
            let a = max(region.start, p.clip.start), b = min(region.end, p.clip.end)
            return b > a ? p.timelineTime(a)...p.timelineTime(b) : nil
        }
    }

    // MARK: Social

    /// A vertical copy of the project built from the best 30–60 s (picked by Claude from the
    /// transcript; without AI, the stretch with the most speech), with captions and a title.
    func makeShort() {
        guard begin("short", "Claude is picking the best part for your short…") else { return }
        aiStatus = "Picking the best part…"
        Task {
            defer { end("short") }
            do {
                try await ensureWords()
                let lines = transcriptLines()
                var ranges: [ClosedRange<Double>] = []
                var title: String?
                if !lines.isEmpty, let answer = try? await AIClient.ask(system: AIEditor.shortSystemPrompt, prompt: AIEditor.shortPrompt(lines: lines, duration: totalDuration)),
                   let json = try? AIClient.json(in: answer) {
                    ranges = (json["ranges"] as? [[String: Any]] ?? []).compactMap {
                        guard let a = AIEditor.number($0["start"]), let b = AIEditor.number($0["end"]), b > a else { return nil }
                        return max(0, a)...min(totalDuration, b)
                    }
                    title = json["title"] as? String
                }
                if ranges.isEmpty { ranges = [densestSpeech(lines: lines, length: min(45, totalDuration))] }
                try buildShort(keeping: ranges, title: title)
            } catch {
                aiStatus = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func densestSpeech(lines: [Captioner.Word], length: Double) -> ClosedRange<Double> {
        guard totalDuration > length else { return 0...totalDuration }
        var best = 0.0, bestStart = 0.0
        var start = 0.0
        while start + length <= totalDuration {
            let speech = lines.reduce(0) { $0 + max(0, min($1.end, start + length) - max($1.start, start)) }
            if speech > best { best = speech; bestStart = start }
            start += 1
        }
        return bestStart...(bestStart + length)
    }

    private func buildShort(keeping ranges: [ClosedRange<Double>], title: String?) throws {
        saveNow()
        let fm = FileManager.default
        let folder = try ProjectStore.newProjectFolder(prefix: "Short")
        try fm.removeItem(at: folder)
        try fm.copyItem(at: project.url, to: folder)
        var short = try ProjectStore.load(folder)
        let keep = EditOps.merge(ranges)
        var removals: [ClosedRange<Double>] = []
        var cursor = 0.0
        for r in keep {
            if r.lowerBound > cursor { removals.append(cursor...r.lowerBound) }
            cursor = r.upperBound
        }
        if cursor < totalDuration { removals.append(cursor...totalDuration) }
        let cut = EditOps.remove(removals, from: content, project: snapshot)
        short.doc.name = "\(name) – Short"
        short.doc.clips = cut.clips
        short.doc.texts = cut.texts
        short.doc.cameraKeys = cut.cameraKeys
        short.doc.settings.aspect = .vertical
        short.doc.settings.reframe = true
        short.doc.settings.cameraShape = .circle
        short.doc.settings.cameraCorner = .bottomRight
        short.doc.settings.cameraX = nil
        short.doc.settings.cameraY = nil
        // A hook title from Claude, unless a title already sits at the start.
        if let title, !title.isEmpty, !short.doc.texts.contains(where: { !$0.caption && $0.start < 3.5 }) {
            short.doc.texts.append(TextOverlay(text: title, start: 0, end: min(3.5, TimelineLayout.duration(of: short)),
                                               x: 0.5, y: 0.12, size: 0.045, color: 0xFFFFFF, style: .pill))
        }
        try short.save()
        aiStatus = "Created “\(short.doc.name)” (\(formatDuration(TimelineLayout.duration(of: short))))."
        openProject?(folder)
    }

    // MARK: Prompt editing

    func runAIPrompt() {
        let request = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, begin("ai", "Claude is editing: “\(request.prefix(40))”") else { return }
        aiStatus = "Thinking…"
        Task {
            defer { end("ai") }
            do {
                if !placements.filter({ Cleanup.voiceTrack(of: $0) != nil }).isEmpty { try? await ensureWords() }
                aiStatus = "Asking Claude…"
                let answer = try await AIClient.ask(system: AIEditor.systemPrompt, prompt: AIEditor.prompt(for: self, request: request))
                let json = try AIClient.json(in: answer)
                let operations = json["operations"] as? [[String: Any]] ?? []
                let applied = await AIEditor.apply(operations, to: self)
                let summary = json["summary"] as? String
                aiStatus = applied.isEmpty
                    ? (summary ?? "Nothing to change.")
                    : (summary.map { $0 + "\n" } ?? "") + applied.map { "• " + $0 }.joined(separator: "\n")
                if !applied.isEmpty { aiPrompt = "" }
            } catch {
                aiStatus = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-renders the paused frame (after background analysis changed what the renderer reads).
    func refreshPreview() { rebuild(delay: false) }
}
