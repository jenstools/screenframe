import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    enum Selection: Equatable {
        case clip(UUID)
        case zoom(clip: UUID, zoom: UUID)
        case text(UUID)
        case cameraKey(UUID)
        case blur(UUID)
    }

    typealias Placement = ClipPlacement

    struct PlacedZoom: Identifiable {
        var id: UUID { segment.id }
        let placement: Placement
        let segment: ZoomSegment
        /// Timeline span, clipped to the clip.
        let start: Double
        let end: Double
    }

    /// Everything undo restores.
    private struct EditState: Equatable {
        var settings: EditSettings
        var clips: [Clip]
        var texts: [TextOverlay]
        var cameraKeys: [CameraKey]
        var blurs: [BlurRegion]
    }

    @Published private(set) var project: Project
    @Published var settings: EditSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.zoomLevel != oldValue.zoomLevel {
                for c in clips.indices {
                    for z in clips[c].zooms.indices where clips[c].zooms[z].auto { clips[c].zooms[z].zoom = settings.zoomLevel }
                }
            }
            changed()
        }
    }
    @Published var clips: [Clip] { didSet { if clips != oldValue { changed() } } }
    @Published var texts: [TextOverlay] { didSet { if texts != oldValue { changed() } } }
    @Published var cameraKeys: [CameraKey] { didSet { if cameraKeys != oldValue { changed() } } }
    @Published var blurs: [BlurRegion] { didSet { if blurs != oldValue { changed() } } }
    /// Proposed cuts (silences, filler words), shown on the timeline until applied or cleared.
    @Published var cutSuggestions: [CutSuggestion] = []
    @Published var keepSilentDemos = true
    @Published var aiPrompt = ""
    @Published var aiStatus: String?
    // Busy states, all derived from the activity list (see Activities).
    var aiBusy: Bool { isRunning("ai") || isRunning("short") }
    @Published var analysisStatus: String?
    var privacyProgress: Double? { progress(of: "privacy") }
    var faceProgress: Double? { progress(of: "faces") }
    /// Something long-running (AI, transcription, export…), shown in the activity strip on the preview.
    struct Activity: Identifiable, Equatable {
        let id: String
        var title: String
        var progress: Double?
        let started: Date
    }

    @Published private(set) var activities: [Activity] = []
    /// Short confirmation after a task finishes (or a "already running" notice).
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?
    /// The transcription in flight, so features needing words share one run.
    var wordsTask: Task<Void, Error>?

    func isRunning(_ id: String) -> Bool { activities.contains { $0.id == id } }

    func progress(of id: String) -> Double? {
        activities.first { $0.id == id }.map { $0.progress ?? 0 }
    }

    /// Starts a task unless it's already running (double-clicks just show a notice).
    func begin(_ id: String, _ title: String) -> Bool {
        if let running = activities.first(where: { $0.id == id }) {
            show("Already running: \(running.title)")
            return false
        }
        activities.append(Activity(id: id, title: title, progress: nil, started: Date()))
        return true
    }

    func report(_ id: String, progress value: Double?, title: String? = nil) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        if let value { activities[i].progress = min(1, max(0, value)) }
        if let title { activities[i].title = title }
    }

    func end(_ id: String, _ message: String? = nil) {
        activities.removeAll { $0.id == id }
        if let message { show(message) }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    enum Sheet: String, Identifiable {
        case content, thumbnail, brandKits
        var id: String { rawValue }
    }

    @Published var activeSheet: Sheet?
    /// Selected word range in the transcript (indices into `transcriptWords`).
    @Published var transcriptSelection: ClosedRange<Int>?
    var transcribing: Bool { isRunning("words") }
    @Published var brandKits: [BrandKit] = BrandKitStore.load()
    var applyingBrand: Bool { isRunning("brand") }
    @Published var contentPackage: ContentPackage?
    var contentBusy: Bool { isRunning("content") }
    var guideProgress: Double? { progress(of: "guide") }
    @Published var thumbnailCandidates: [ThumbnailMaker.Candidate] = []
    var thumbnailBusy: Bool { isRunning("thumbnail") }
    /// Brand names and terms for transcription and subtitle fixes (app-wide).
    @Published var glossary: [GlossaryEntry] = Glossary.load()
    /// Subtitles Claude just changed, marked in the subtitle editor for review.
    @Published var recentlyFixed: Set<UUID> = []
    /// The text of each line before Claude's fix (for "Learn from fixes").
    var fixOriginals: [UUID: String] = [:]
    /// Opens the subtitle editor window (wired up by the app delegate).
    var openSubtitleEditor: (() -> Void)?

    /// Where the last generated files went (content, thumbnails, guide), for "Show in Finder".
    @Published var lastOutputFolder: URL?

    /// The preview's render models per clip, for mapping blur boxes onto the preview.
    var renderModels: [UUID: RenderModel] = [:]
    /// Opens another project (used by "Make Short").
    var openProject: ((URL) -> Void)?
    /// Transcribed words per audio file path, reused by captions, cleanup and AI.
    var wordsByFile: [String: [Captioner.Word]] = [:]
    @Published var selection: Selection?
    @Published private(set) var currentTime = 0.0
    @Published private(set) var isPlaying = false
    var exportProgress: Double? { progress(of: "export") }
    @Published private(set) var lastExport: URL?
    @Published var errorMessage: String?
    /// Audio file path → peaks.
    @Published private(set) var waveforms: [String: [Float]] = [:]
    @Published private(set) var canvasSize = CGSize(width: 1920, height: 1080)
    var importing: Bool { isRunning("import") }
    var captionProgress: Double? { progress(of: "captions") }
    @Published var captionLanguage = UserDefaults.standard.string(forKey: "captionLanguage") ?? "de-DE" {
        didSet { UserDefaults.standard.set(captionLanguage, forKey: "captionLanguage") }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rebuildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var structureKey = ""
    private var loadingWaveforms: Set<String> = []
    private var frameGenerators: [URL: AVAssetImageGenerator] = [:]
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var lastState: EditState
    private var lastChange = Date.distantPast
    private var restoring = false

    init(project: Project) {
        self.project = project
        self.settings = project.doc.settings
        self.clips = project.doc.clips
        self.texts = project.doc.texts
        self.cameraKeys = project.doc.cameraKeys
        self.blurs = project.doc.blurs
        self.lastState = EditState(settings: project.doc.settings, clips: project.doc.clips, texts: project.doc.texts,
                                   cameraKeys: project.doc.cameraKeys, blurs: project.doc.blurs)
        player.currentItem?.audioTimePitchAlgorithm = .spectral
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player.rate > 0
            }
        }
        rebuild(delay: false)
        loadWaveforms()
        analyzeFaces()
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        saveNow()
    }

    var name: String { project.doc.name }

    /// The project with the current edit applied.
    var snapshot: Project {
        var p = project
        p.doc.settings = settings
        p.doc.clips = clips
        p.doc.texts = texts
        p.doc.cameraKeys = cameraKeys
        p.doc.blurs = blurs
        return p
    }

    /// Clips, texts and camera keys together, for structural edits (EditOps).
    var content: EditContent {
        get { EditContent(clips: clips, texts: texts, cameraKeys: cameraKeys) }
        set {
            clips = newValue.clips
            texts = newValue.texts
            cameraKeys = newValue.cameraKeys
        }
    }

    // MARK: Layout

    var placements: [Placement] { TimelineLayout.place(clips, in: project) }
    var totalDuration: Double { placements.last?.end ?? 0 }

    func placement(at t: Double) -> Placement? {
        let all = placements
        return all.first { t < $0.end } ?? all.last
    }

    func placement(of id: UUID) -> Placement? { placements.first { $0.clip.id == id } }

    var placedZooms: [PlacedZoom] {
        placements.flatMap { p in
            p.clip.zooms.compactMap { z -> PlacedZoom? in
                let start = max(p.offset, p.timelineTime(z.start)), end = min(p.end, p.timelineTime(z.end))
                return end - start > 0.05 ? PlacedZoom(placement: p, segment: z, start: start, end: end) : nil
            }
        }
    }

    var titles: [TextOverlay] { texts.filter { !$0.caption } }
    var captions: [TextOverlay] { texts.filter(\.caption) }
    var hasWebcam: Bool { placements.contains { $0.media.info.webcam != nil } }

    // MARK: Undo

    private var state: EditState {
        EditState(settings: settings, clips: clips, texts: texts, cameraKeys: cameraKeys, blurs: blurs)
    }

    /// Changes within 0.6 s of each other (a slider drag, a timeline drag) undo as one step.
    private func recordUndo() {
        guard !restoring else { return }
        let current = state
        guard current != lastState else { return }
        if Date().timeIntervalSince(lastChange) > 0.6 {
            undoStack.append(lastState)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastState = current
        lastChange = Date()
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        restore(next)
    }

    private func restore(_ state: EditState) {
        restoring = true
        settings = state.settings
        clips = state.clips
        texts = state.texts
        cameraKeys = state.cameraKeys
        blurs = state.blurs
        restoring = false
        lastState = state
        lastChange = .distantPast
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if case .text(let id) = selection, !texts.contains(where: { $0.id == id }) { selection = nil }
        if case .clip(let id) = selection, !clips.contains(where: { $0.id == id }) { selection = nil }
        seek(to: currentTime)
    }

    // MARK: Playback

    func togglePlay() {
        if player.rate > 0 {
            player.pause()
        } else {
            if currentTime >= totalDuration - 0.05 { seek(to: 0) }
            player.play()
        }
        isPlaying = player.rate > 0
    }

    func seek(to time: Double) {
        let t = min(max(time, 0), totalDuration)
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Editor keys, routed here unless a text field is being edited.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) {
            switch key {
            case "z" where flags.contains(.shift): redo()
            case "z": undo()
            case "b": splitAtPlayhead()
            case "d": duplicateSelection()
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 49: togglePlay()
        case 51, 117:
            if transcriptSelection != nil { cutTranscriptSelection() } else { deleteSelection() }
        case 123: seek(to: currentTime - (flags.contains(.shift) ? 1 : 1.0 / 30))
        case 124: seek(to: currentTime + (flags.contains(.shift) ? 1 : 1.0 / 30))
        default:
            switch key {
            case "z": toggleZooms()
            case "t": addText()
            case "b": splitAtPlayhead()
            default: return false
            }
        }
        return true
    }

    // MARK: Clips

    var selectedPlacement: Placement? {
        guard case .clip(let id) = selection else { return nil }
        return placement(of: id)
    }

    func addClips() {
        let panel = NSOpenPanel()
        panel.title = "Add clips"
        panel.message = "Choose video files or ScreenFrame recordings to add after the selected clip."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie]
        panel.directoryURL = ProjectStore.root
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await insertClips(from: urls) }
    }

    func insertClips(from urls: [URL]) async {
        guard begin("import", urls.count == 1 ? "Adding clip…" : "Adding \(urls.count) clips…") else { return }
        defer { end("import") }
        var insertAt = selectedPlacement.map { $0.index + 1 } ?? clips.count
        for url in urls {
            do {
                let clip = try await ProjectStore.importClip(from: url, into: snapshot)
                clips.insert(clip, at: min(insertAt, clips.count))
                insertAt += 1
                selection = .clip(clip.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        loadWaveforms()
    }

    private func updateClip(_ id: UUID, _ change: (inout Clip) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        change(&clips[i])
    }

    /// Splits at a timeline time (default: the playhead). Both halves keep the clip's settings.
    func split(at time: Double? = nil) {
        let t = time ?? currentTime
        guard let p = placement(at: t) else { return }
        let s = p.sourceTime(t)
        guard s - p.clip.start > 0.1, p.clip.end - s > 0.1 else { return }
        var first = p.clip
        first.end = s
        first.transition = nil
        var second = p.clip
        second.id = UUID()
        second.start = s
        second.zooms = p.clip.zooms.map { var z = $0; z.id = UUID(); return z }
        clips[p.index] = first
        clips.insert(second, at: p.index + 1)
        selection = .clip(second.id)
    }

    func splitAtPlayhead() { split() }

    func moveClip(_ id: UUID, by delta: Int) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips.indices.contains(i + delta) else { return }
        clips.swapAt(i, i + delta)
    }

    func moveSelectedClip(by delta: Int) {
        guard let p = selectedPlacement else { return }
        moveClip(p.clip.id, by: delta)
    }

    func trimClip(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let i = clips.firstIndex(where: { $0.id == id }), let media = project.media(for: clips[i]) else { return }
        var clip = clips[i]
        if let start { clip.start = min(max(0, start), clip.end - 0.2) }
        if let end { clip.end = max(min(media.info.duration, end), clip.start + 0.2) }
        clips[i] = clip
    }

    func setClipStartToPlayhead() {
        guard let p = selectedPlacement, currentTime >= p.offset, currentTime <= p.end else { return }
        trimClip(p.clip.id, start: p.sourceTime(currentTime))
    }

    func setClipEndToPlayhead() {
        guard let p = selectedPlacement, currentTime >= p.offset, currentTime <= p.end else { return }
        trimClip(p.clip.id, end: p.sourceTime(currentTime))
    }

    func renameClip(_ id: UUID, _ name: String) { updateClip(id) { $0.name = name } }
    func setSpeed(_ id: UUID, _ speed: Double) { updateClip(id) { $0.speed = min(8, max(0.1, speed)) } }
    func setClipVolume(_ id: UUID, kind: String, _ volume: Double) { updateClip(id) { $0.setVolume(min(1, max(0, volume)), for: kind) } }
    func setCameraLayout(_ id: UUID, _ layout: Clip.CameraLayout) { updateClip(id) { $0.camera = layout } }

    func setTransition(_ id: UUID, _ kind: ClipTransition.Kind?) {
        updateClip(id) { clip in
            clip.transition = kind.map { ClipTransition(kind: $0, duration: clip.transition?.duration ?? 0.6) }
        }
    }

    func setTransitionDuration(_ id: UUID, _ duration: Double) {
        updateClip(id) { $0.transition?.duration = max(0.1, min(3, duration)) }
    }

    func duplicateClip(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        var copy = clips[i]
        copy.id = UUID()
        copy.zooms = copy.zooms.map { var z = $0; z.id = UUID(); return z }
        clips.insert(copy, at: i + 1)
        selection = .clip(copy.id)
    }

    /// Typing stretches of a clip (from the recorded key-press times).
    func typingRanges(in p: Placement) -> [ClosedRange<Double>] {
        guard let keys = p.media.info.keystrokes, !keys.isEmpty else { return [] }
        var ranges: [ClosedRange<Double>] = []
        var start = keys[0], last = keys[0], count = 1
        func close() {
            if count >= 8, last - start >= 2 { ranges.append(start...(last + 0.2)) }
        }
        for key in keys.dropFirst().sorted() {
            if key - last <= 1.2 {
                last = key
                count += 1
            } else {
                close()
                start = key
                last = key
                count = 1
            }
        }
        close()
        return ranges.compactMap { r in
            let lo = max(r.lowerBound, p.clip.start), hi = min(r.upperBound, p.clip.end)
            return hi - lo > 1 ? lo...hi : nil
        }
    }

    /// Splits the clip around its typing stretches and plays those at `settings.typingSpeed`.
    func speedUpTyping(_ id: UUID) {
        guard let p = placement(of: id) else { return }
        let ranges = typingRanges(in: p)
        guard !ranges.isEmpty else { return }
        var pieces: [Clip] = []
        var cursor = p.clip.start
        func piece(_ from: Double, _ to: Double, speed: Double) {
            guard to - from > 0.05 else { return }
            var clip = p.clip
            clip.id = pieces.isEmpty ? p.clip.id : UUID()
            clip.start = from
            clip.end = to
            clip.speed = speed
            clip.transition = nil
            clip.zooms = clip.zooms.map { var z = $0; if !pieces.isEmpty { z.id = UUID() }; return z }
            pieces.append(clip)
        }
        for range in ranges {
            piece(cursor, range.lowerBound, speed: p.clip.speed)
            piece(range.lowerBound, range.upperBound, speed: settings.typingSpeed)
            cursor = range.upperBound
        }
        piece(cursor, p.clip.end, speed: p.clip.speed)
        pieces[pieces.count - 1].transition = p.clip.transition
        clips.replaceSubrange(p.index...p.index, with: pieces)
    }

    func deleteSelection() {
        switch selection {
        case .clip(let id):
            guard clips.count > 1 else {
                errorMessage = "A project needs at least one clip."
                return
            }
            clips.removeAll { $0.id == id }
        case .zoom(let clipID, let zoomID):
            updateClip(clipID) { $0.zooms.removeAll { $0.id == zoomID } }
        case .text(let id):
            texts.removeAll { $0.id == id }
        case .cameraKey(let id):
            cameraKeys.removeAll { $0.id == id }
        case .blur(let id):
            blurs.removeAll { $0.id == id }
        case nil:
            return
        }
        selection = nil
        seek(to: currentTime)
    }

    func duplicateSelection() {
        switch selection {
        case .clip(let id): duplicateClip(id)
        case .zoom(let clipID, let zoomID): duplicateZoom(clip: clipID, zoom: zoomID)
        case .text(let id): duplicateText(id)
        case .cameraKey, .blur, nil: break
        }
    }

    // MARK: Zooms

    /// Master switch: turns every zoom off (or back on) without touching the segments.
    func toggleZooms() { settings.autoZoom.toggle() }

    var selectedZoom: PlacedZoom? {
        guard case .zoom(let clipID, let zoomID) = selection,
              let p = placement(of: clipID),
              let z = p.clip.zooms.first(where: { $0.id == zoomID }) else { return nil }
        return PlacedZoom(placement: p, segment: z, start: p.timelineTime(z.start), end: p.timelineTime(z.end))
    }

    func addZoom() {
        guard let p = placement(at: currentTime) else { return }
        let s = min(p.sourceTime(currentTime), max(0, p.clip.end - 0.5))
        let segment = ZoomSegment(start: s, end: min(p.clip.end, s + 2.5 * p.speed), zoom: settings.zoomLevel, auto: false)
        updateClip(p.clip.id) {
            $0.zooms.append(segment)
            $0.zooms.sort { $0.start < $1.start }
        }
        selection = .zoom(clip: p.clip.id, zoom: segment.id)
        if !settings.autoZoom { settings.autoZoom = true }
    }

    func regenerateZooms() {
        for p in placements where p.media.kind == .recording {
            let manual = clips[p.index].zooms.filter { !$0.auto }
            clips[p.index].zooms = (manual + AutoZoom.generate(info: p.media.info, zoom: settings.zoomLevel)).sorted { $0.start < $1.start }
        }
        if case .zoom = selection { selection = nil }
    }

    /// Edits to a generated segment turn it into a manual one, so "Regenerate" keeps it.
    func updateZoom(clip clipID: UUID, zoom zoomID: UUID, _ change: (inout ZoomSegment) -> Void) {
        guard let c = clips.firstIndex(where: { $0.id == clipID }),
              let z = clips[c].zooms.firstIndex(where: { $0.id == zoomID }),
              let media = project.media(for: clips[c]) else { return }
        var segment = clips[c].zooms[z]
        change(&segment)
        segment.auto = false
        segment.start = max(0, min(segment.start, media.info.duration - 0.2))
        segment.end = min(media.info.duration, max(segment.end, segment.start + 0.2))
        clips[c].zooms[z] = segment
    }

    func updateSelectedZoom(_ change: (inout ZoomSegment) -> Void) {
        guard case .zoom(let clipID, let zoomID) = selection else { return }
        updateZoom(clip: clipID, zoom: zoomID, change)
    }

    func duplicateZoom(clip clipID: UUID, zoom zoomID: UUID) {
        guard let c = clips.firstIndex(where: { $0.id == clipID }),
              var copy = clips[c].zooms.first(where: { $0.id == zoomID }) else { return }
        let length = copy.end - copy.start
        copy.id = UUID()
        copy.auto = false
        copy.start = copy.end + 0.3
        copy.end = copy.start + length
        clips[c].zooms.append(copy)
        selection = .zoom(clip: clipID, zoom: copy.id)
    }

    /// nil = follow the cursor.
    func setSelectedFocus(_ point: CGPoint?) {
        updateSelectedZoom { $0.focus = point }
    }

    /// Where a fixed focus starts when switching away from "follow cursor": the cursor position at
    /// the start of the segment, or the centre for clips without cursor data.
    func defaultFocus(for zoom: PlacedZoom) -> CGPoint {
        let info = zoom.placement.media.info
        guard let p = Motion.rawCursor(info.mouse, at: zoom.segment.start) else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max(p.x / info.sourceWidth, 0), 1), y: min(max(p.y / info.sourceHeight, 0), 1))
    }

    /// Share of a clip's picture visible at `zoom` with the current frame settings.
    func visibleFraction(zoom: Double, in placement: Placement) -> CGSize {
        let rect = RenderModel.videoRect(canvas: canvasSize, source: placement.media.sourceSize, settings: settings)
        return RenderModel.visibleFraction(zoom: zoom, canvas: canvasSize, videoRect: rect)
    }

    /// The raw clip picture (no effects) at a source time, for picking a focus point.
    func sourceFrame(of placement: Placement, at t: Double) async -> CGImage? {
        let url = placement.media.videoURL
        let generator = frameGenerators[url] ?? {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.maximumSize = CGSize(width: 640, height: 640)
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            frameGenerators[url] = g
            return g
        }()
        return try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    // MARK: Text

    var selectedTextIndex: Int? {
        guard case .text(let id) = selection else { return nil }
        return texts.firstIndex { $0.id == id }
    }

    func addText() {
        let total = totalDuration
        guard total > 0.3 else { return }
        let start = min(currentTime, total - 0.3)
        let text = TextOverlay(start: start, end: min(total, start + 3))
        texts.append(text)
        selection = .text(text.id)
    }

    func updateText(_ id: UUID, _ change: (inout TextOverlay) -> Void) {
        guard let i = texts.firstIndex(where: { $0.id == id }) else { return }
        var text = texts[i]
        change(&text)
        let total = max(0.3, totalDuration)
        text.start = max(0, min(text.start, total - 0.2))
        text.end = min(total, max(text.end, text.start + 0.2))
        text.x = min(max(text.x, 0), 1)
        text.y = min(max(text.y, 0), 1)
        texts[i] = text
    }

    func duplicateText(_ id: UUID) {
        guard var copy = texts.first(where: { $0.id == id }) else { return }
        let length = copy.end - copy.start
        copy.id = UUID()
        copy.start = min(copy.end, max(0, totalDuration - length))
        copy.end = copy.start + length
        texts.append(copy)
        selection = .text(copy.id)
    }

    /// Texts visible at the playhead, topmost last.
    var visibleTexts: [TextOverlay] { texts.filter { currentTime >= $0.start && currentTime < $0.end } }

    // MARK: Camera bubble

    /// The camera bubble on screen at the playhead (canvas coordinates, bottom-left origin), if any.
    var cameraBubbleRect: CGRect? {
        guard settings.showCamera, let p = placement(at: currentTime), p.media.info.webcam != nil else { return nil }
        let videoRect = RenderModel.videoRect(canvas: canvasSize, source: p.media.sourceSize, settings: settings)
        let placement = RenderModel.CameraPlacement(settings: settings, info: p.media.info, canvas: canvasSize, videoRect: videoRect,
                                                    keys: cameraKeys, baseLayout: p.clip.camera, clipStart: p.offset)
        let state = placement.state(source: p.sourceTime(currentTime), timeline: currentTime)
        return state.overlay > 0.5 ? state.rect : nil
    }

    /// Dragging the bubble on the preview: with keyframes on the Camera lane, sets (or adds) the
    /// keyframe at the playhead; without, moves the bubble for the whole video.
    func dragCamera(to point: CGPoint) {
        guard !cameraKeys.isEmpty else {
            moveCamera(to: point)
            return
        }
        let x = min(max(point.x, 0), 1), y = min(max(point.y, 0), 1)
        if let i = cameraKeys.firstIndex(where: { abs($0.t - currentTime) < 0.15 }) {
            cameraKeys[i].x = x
            cameraKeys[i].y = y
            cameraKeys[i].auto = nil
            selection = .cameraKey(cameraKeys[i].id)
        } else {
            let key = CameraKey(t: currentTime, x: x, y: y, layout: currentCameraLayout)
            cameraKeys.append(key)
            selection = .cameraKey(key.id)
        }
    }

    var hasRecordedCameraPath: Bool { placements.contains { !($0.media.info.webcamPath ?? []).isEmpty } }

    /// Puts the bubble's centre at a point (normalized to the output, top-left origin) and stops
    /// following the recorded position.
    func moveCamera(to point: CGPoint) {
        var s = settings
        s.cameraX = min(max(point.x, 0), 1)
        s.cameraY = min(max(point.y, 0), 1)
        s.cameraFollowsRecording = false
        settings = s
    }

    func setCameraCorner(_ corner: CameraCorner) {
        var s = settings
        s.cameraCorner = corner
        s.cameraX = nil
        s.cameraY = nil
        s.cameraFollowsRecording = false
        settings = s
    }

    // MARK: Captions

    /// Transcribes each clip's voice (or, without a mic track, its other audio) and replaces the
    /// captions. Clips that share a file (after splits) are transcribed once.
    func generateCaptions() {
        guard begin("captions", "Creating captions…") else { return }
        let placements = self.placements
        let language = captionLanguage
        let style = captionStyle
        Task {
            var wordsByFile = self.wordsByFile
            var captions: [TextOverlay] = []
            do {
                let sources = placements.compactMap { p -> (Placement, AudioTrackInfo)? in
                    let audio = p.media.info.audio
                    guard let track = audio.first(where: { $0.kind == "microphone" }) ?? audio.first(where: { $0.kind == "system-audio" })
                        ?? audio.first else { return nil }
                    return (p, track)
                }
                let files = Array(Set(sources.map { $0.0.media.folder.appendingPathComponent($0.1.file).path })).sorted()
                for (i, path) in files.enumerated() where wordsByFile[path] == nil {
                    let base = Double(i) / Double(max(1, files.count))
                    wordsByFile[path] = try await Captioner.words(in: URL(fileURLWithPath: path), language: language) { [weak self] p in
                        Task { @MainActor in self?.report("captions", progress: base + p / Double(max(1, files.count))) }
                    }
                }
                self.wordsByFile = wordsByFile
                for (p, track) in sources {
                    let words = wordsByFile[p.media.folder.appendingPathComponent(track.file).path] ?? []
                    // File time → source time → timeline, keeping only words inside the clip.
                    let inClip = words.compactMap { w -> Captioner.Word? in
                        let s0 = w.start + track.offset, s1 = w.end + track.offset
                        guard s0 >= p.clip.start, s1 <= p.clip.end + 0.2 else { return nil }
                        return Captioner.Word(text: w.text, start: p.timelineTime(s0), end: min(p.end, p.timelineTime(s1)))
                    }
                    captions += Captioner.lines(from: inClip).map {
                        var line = TextOverlay(text: $0.text, start: $0.start, end: $0.end, x: 0.5, isCaption: true)
                        style.apply(to: &line)
                        return line
                    }
                }
                texts = texts.filter { !$0.caption } + captions
                if captions.isEmpty { errorMessage = "No speech was recognized." }
            } catch {
                errorMessage = error.localizedDescription
            }
            end("captions", captions.isEmpty ? nil : "Added \(captions.count) captions")
        }
    }

    func removeCaptions() {
        texts.removeAll(where: \.caption)
        if case .text(let id) = selection, !texts.contains(where: { $0.id == id }) { selection = nil }
    }

    // MARK: Audio

    /// Audio lanes that have sound in at least one clip.
    var audioLanes: [String] {
        let present = Set(placements.flatMap { p in
            p.media.info.audio.filter { !(waveforms[p.media.folder.appendingPathComponent($0.file).path] ?? []).isEmpty }.map(\.kind)
        })
        return Composer.audioKinds.filter(present.contains)
    }

    /// Lanes this clip has sound on.
    func audioKinds(of p: Placement) -> [String] {
        let kinds = Set(p.media.info.audio.filter { !(waveforms[p.media.folder.appendingPathComponent($0.file).path] ?? []).isEmpty }.map(\.kind))
        return Composer.audioKinds.filter(kinds.contains)
    }

    static func laneName(_ kind: String) -> String {
        switch kind {
        case "microphone": return "Voice"
        case "system-audio": return "System audio"
        default: return "Clip audio"
        }
    }

    static func laneSymbol(_ kind: String) -> String {
        switch kind {
        case "microphone": return "mic.fill"
        case "system-audio": return "speaker.wave.2.fill"
        default: return "film"
        }
    }

    func volume(_ kind: String) -> Double { settings.volumes[kind] ?? 1 }
    func setVolume(_ kind: String, _ value: Double) { settings.volumes[kind] = value }
    func isMuted(_ kind: String) -> Bool { settings.muted.contains(kind) }
    func toggleMute(_ kind: String) {
        if let i = settings.muted.firstIndex(of: kind) { settings.muted.remove(at: i) } else { settings.muted.append(kind) }
    }

    private func loadWaveforms() {
        for p in placements {
            for audio in p.media.info.audio {
                let url = p.media.folder.appendingPathComponent(audio.file)
                guard waveforms[url.path] == nil, !loadingWaveforms.contains(url.path),
                      FileManager.default.fileExists(atPath: url.path) else { continue }
                loadingWaveforms.insert(url.path)
                Task.detached(priority: .utility) {
                    let peaks = await Waveform.peaks(of: url)
                    await MainActor.run {
                        self.waveforms[url.path] = peaks
                        self.loadingWaveforms.remove(url.path)
                    }
                }
            }
        }
    }

    private func changed() {
        recordUndo()
        rebuild(delay: true)
        scheduleSave()
    }

    // MARK: Composition

    func rebuild(delay: Bool) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if delay { try? await Task.sleep(for: .milliseconds(35)) }
            guard let self, !Task.isCancelled else { return }
            let project = self.snapshot
            do {
                let built = try await Composer.build(project: project, maxLongSide: 1920, resolution: nil)
                guard !Task.isCancelled else { return }
                let structure = project.doc.clips.map {
                    "\($0.id)|\($0.source)|\($0.start)|\($0.end)|\($0.speed)|\($0.transition?.kind.rawValue ?? "")|\($0.transition?.duration ?? 0)"
                }.joined(separator: ",")
                self.apply(built, structure: structure)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ built: BuiltComposition, structure: String) {
        canvasSize = built.canvas
        renderModels = Dictionary((built.videoComposition.instructions as? [FrameInstruction] ?? [])
            .flatMap { $0.layers.map { ($0.model.clipID, $0.model) } }, uniquingKeysWith: { first, _ in first })
        if player.currentItem == nil || structure != structureKey {
            let resume = currentTime
            let item = AVPlayerItem(asset: built.asset)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            structureKey = structure
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isPlaying = false }
            }
            seek(to: resume)
        } else if let item = player.currentItem {
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            // A paused player doesn't redraw on its own.
            if player.rate == 0 { item.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil) }
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        project = snapshot
        do { try project.save() } catch { errorMessage = "Could not save: \(error.localizedDescription)" }
    }

    // MARK: Export

    func export() {
        guard !isRunning("export") else { show("Already exporting"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(name).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveNow()
        let project = self.project
        guard begin("export", "Exporting “\(url.lastPathComponent)”…") else { return }
        Task {
            do {
                try await Exporter.export(project: project, to: url) { [weak self] p in
                    Task { @MainActor in self?.report("export", progress: p) }
                }
                lastExport = url
                end("export", "Exported \(url.lastPathComponent)")
            } catch {
                end("export")
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func revealExport() {
        guard let lastExport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExport])
    }

    /// Puts the exported file on the clipboard, ready to paste into Slack, LinkedIn, Mail…
    func copyExport() {
        guard let lastExport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([lastExport as NSURL])
    }
}
