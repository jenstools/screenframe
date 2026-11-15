import AppKit
import Foundation

/// How the camera sits in a short.
enum ShortLayout: String, CaseIterable, Identifiable {
    case split, bubble, camera, screen
    var id: String { rawValue }

    var label: String {
        switch self {
        case .split: return "Split"
        case .bubble: return "Bubble"
        case .camera: return "Camera"
        case .screen: return "Screen"
        }
    }

    var detail: String {
        switch self {
        case .split: return "Screen on top, you below"
        case .bubble: return "Screen with a round camera"
        case .camera: return "Only you, full frame"
        case .screen: return "Only the screen"
        }
    }

    var symbol: String {
        switch self {
        case .split: return "rectangle.split.1x2"
        case .bubble: return "person.crop.circle"
        case .camera: return "person.crop.rectangle"
        case .screen: return "display"
        }
    }

    var cameraLayout: Clip.CameraLayout {
        switch self {
        case .split: return .split
        case .bubble: return .overlay
        case .camera: return .fullscreen
        case .screen: return .hidden
        }
    }

    init(_ layout: Clip.CameraLayout) {
        switch layout {
        case .split: self = .split
        case .overlay: self = .bubble
        case .fullscreen: self = .camera
        case .hidden: self = .screen
        }
    }

}

/// The Social tab: shorts cut from this video (or, in a short, its post text and layout).
extension EditorModel {
    func startSocial() {
        shortInfo = ShortStore.load(project.url)
        reloadShorts()
        // No queue: a `.main` queue would make the post (itself on the main actor) wait on itself.
        shortObserver = NotificationCenter.default.addObserver(forName: ShortStore.changed, object: nil, queue: nil) { [weak self] note in
            guard let folder = note.object as? URL else { return }
            Task { @MainActor in self?.shortChanged(folder) }
        }
    }

    private func shortChanged(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        if path == project.url.standardizedFileURL.path {
            let info = ShortStore.load(folder)
            if info != shortInfo { shortInfo = info }
        } else if let i = shorts.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
            if let info = ShortStore.load(folder), info != shorts[i].info { shorts[i].info = info }
        }
    }

    var isShort: Bool { shortInfo != nil }

    func reloadShorts() {
        let list = ShortStore.shorts(of: project.url)
        if list != shorts { shorts = list }
    }

    var shortsBusy: Bool { isRunning("shorts") }
    var shortsExporting: Double? { progress(of: "short-export") }

    // MARK: Making shorts

    /// Lets Claude pick `count` new shorts (nil: by length of the video) that don't overlap the
    /// existing ones, and builds each as its own vertical project with captions and a hook title.
    func makeShorts(count: Int? = nil, length: ShortsPlanner.Length = .standard, layout: ShortLayout = .split,
                    style: ShortStyle? = nil) {
        let style = style ?? ShortsDefaults.style(kits: brandKits)
        guard begin("shorts", "Picking shorts…") else { return }
        Task {
            defer { end("shorts") }
            do {
                try await ensureWords()
                let lines = transcriptLines()
                let duration = totalDuration
                let wanted = count ?? ShortsPlanner.autoCount(duration: duration)
                let existing = shorts.flatMap { $0.info.ranges.map { $0.start...$0.end } }
                var plans: [ShortsPlanner.Plan] = []
                var claudeAnswered = false
                if !lines.isEmpty {
                    report("shorts", progress: nil, title: "Claude is picking \(wanted) short\(wanted == 1 ? "" : "s")…")
                    let prompt = ShortsPlanner.prompt(lines: lines, duration: duration, count: wanted, length: length, existing: existing)
                    if let answer = try? await AIClient.ask(system: ShortsPlanner.systemPrompt, prompt: prompt),
                       let json = try? AIClient.json(in: answer) {
                        claudeAnswered = true
                        plans = ShortsPlanner.parse(json, duration: duration, length: length, existing: existing)
                        // Claude found nothing worth posting: say why rather than cut random stretches.
                        if plans.isEmpty {
                            let reason = (json["error"] as? String) ?? (json["reason"] as? String)
                            errorMessage = "Claude found no moments that work as a short."
                                + (reason.map { "\n\n\($0)" } ?? " Try a shorter length or check the transcript in the Script tab.")
                            return
                        }
                    }
                }
                let picked = claudeAnswered ? "Claude" : "most speech, Claude unavailable"
                if plans.isEmpty {
                    plans = ShortsPlanner.fallback(lines: lines, duration: duration, count: wanted, length: length, existing: existing)
                }
                plans = Array(plans.prefix(wanted))
                guard !plans.isEmpty else {
                    errorMessage = existing.isEmpty ? "This video is too short for a short." : "No room left for another short that doesn't repeat an existing one."
                    return
                }
                var index = shorts.map(\.info.index).max() ?? 0
                for (i, plan) in plans.enumerated() {
                    report("shorts", progress: Double(i) / Double(plans.count), title: "Building short \(i + 1) of \(plans.count)…")
                    index += 1
                    try buildShort(plan, index: index, layout: hasWebcam ? layout : .screen, lines: lines, style: style)
                    await Task.yield()
                }
                reloadShorts()
                end("shorts", "Created \(plans.count) short\(plans.count == 1 ? "" : "s") (\(picked))")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Kept for the one-click card and older CLI use.
    func makeShort() { makeShorts(count: 1) }

    @discardableResult
    private func buildShort(_ plan: ShortsPlanner.Plan, index: Int, layout: ShortLayout, lines: [Captioner.Word],
                            style: ShortStyle) throws -> URL {
        saveNow()
        let fm = FileManager.default
        let folder = try ProjectStore.newProjectFolder(prefix: "Short")
        try fm.removeItem(at: folder)
        // APFS clones the media, so a copy costs almost no disk space.
        try fm.copyItem(at: project.url, to: folder)
        for leftover in ["content", "thumbnails", "guide", ShortStore.fileName] {
            try? fm.removeItem(at: folder.appendingPathComponent(leftover))
        }
        var short = try ProjectStore.load(folder)

        let keep = EditOps.merge(plan.ranges)
        var removals: [ClosedRange<Double>] = []
        var cursor = 0.0
        for r in keep {
            if r.lowerBound > cursor { removals.append(cursor...r.lowerBound) }
            cursor = r.upperBound
        }
        if cursor < totalDuration { removals.append(cursor...totalDuration) }

        // Captions are rebuilt from the transcript (the style below gives them their look); titles
        // of the original come along, an old hook doesn't.
        var source = content
        source.texts = source.texts.filter { !$0.caption && !$0.isHook } + lines.map {
            TextOverlay(text: $0.text, start: $0.start, end: $0.end, x: 0.5, isCaption: true)
        }
        let cut = EditOps.remove(removals, from: source, project: snapshot)

        short.doc.name = "\(name) – Short \(index)"
        short.doc.clips = cut.clips.map { clip in
            var clip = clip
            if clip.isCard != true { clip.camera = layout.cameraLayout }
            return clip
        }
        // Keyframes were placed for the wide frame; the short uses one layout throughout.
        short.doc.cameraKeys = []
        short.doc.settings.aspect = .vertical
        short.doc.settings.reframe = true
        short.doc.settings.showCamera = true
        short.doc.settings.cameraShape = .circle
        short.doc.settings.cameraCorner = .bottomRight
        short.doc.settings.cameraX = nil
        short.doc.settings.cameraY = nil
        let hook = plan.hook.isEmpty ? plan.title : plan.hook
        var texts = cut.texts
        style.apply(to: &short.doc.settings, texts: &texts, layout: layout,
                    duration: TimelineLayout.duration(of: short), hookText: hook)
        short.doc.texts = texts
        try short.save()

        var info = ShortInfo(parentPath: project.url.standardizedFileURL.path, parentName: name, index: index,
                             title: plan.title.isEmpty ? hook : plan.title, description: plan.description,
                             hashtags: plan.hashtags, ranges: keep.map { .init(start: $0.lowerBound, end: $0.upperBound) })
        info.hook = hook
        info.styleName = style.name
        try ShortStore.save(info, in: folder)
        return folder
    }

    // MARK: Style

    /// The look this short has right now, read from its settings and texts.
    var shortStyle: ShortStyle {
        ShortStyle.read(settings: settings, texts: texts, name: shortInfo?.styleName ?? "Custom")
    }

    /// Restyles this short (one undo step).
    func applyShortStyle(_ style: ShortStyle) {
        var s = settings, t = texts
        style.apply(to: &s, texts: &t, layout: shortLayout, duration: totalDuration,
                    hookText: shortInfo?.hook ?? shortInfo?.title)
        if s != settings { settings = s }
        if t != texts { texts = t }
        if var info = shortInfo, info.styleName != style.name {
            info.styleName = style.name
            updateShortInfo(info)
        }
    }

    /// Edits one property of this short's style.
    func editShortStyle(_ change: (inout ShortStyle) -> Void) {
        var style = shortStyle
        change(&style)
        style.name = "Custom"
        applyShortStyle(style)
    }

    /// Restyles every short of this video. Open shorts are restyled in their window (so its next
    /// save doesn't undo it), the others on disk.
    func applyStyleToAllShorts(_ style: ShortStyle) { applyStyle(style, to: shorts) }

    /// In a short: restyles it and every other short of the same video.
    func applyStyleToSiblings(_ style: ShortStyle) {
        guard let info = shortInfo else { return }
        applyShortStyle(style)
        saveNow()
        applyStyle(style, to: ShortStore.shorts(of: info.parentURL).filter {
            $0.url.standardizedFileURL.path != project.url.standardizedFileURL.path
        }, including: 1)
    }

    private func applyStyle(_ style: ShortStyle, to entries: [ShortEntry], including extra: Int = 0) {
        var count = extra
        for entry in entries {
            if let open = editorFor?(entry.url) {
                open.applyShortStyle(style)
                open.saveNow()
            } else if var short = try? ProjectStore.load(entry.url) {
                var texts = short.doc.texts
                let layout = ShortLayout(short.doc.clips.first { $0.isCard != true }?.camera ?? .overlay)
                style.apply(to: &short.doc.settings, texts: &texts, layout: layout,
                            duration: TimelineLayout.duration(of: short), hookText: entry.info.hook ?? entry.info.title)
                short.doc.texts = texts
                try? short.save()
                var info = entry.info
                info.styleName = style.name
                try? ShortStore.save(info, in: entry.url)
            }
            count += 1
        }
        reloadShorts()
        show("“\(style.name)” applied to \(count) short\(count == 1 ? "" : "s")")
    }

    var shortStyles: [ShortStyle] { ShortStyleStore.all(kits: brandKits) }

    /// The hook title's text (empty when there is none).
    var hookText: String {
        texts.first(where: \.isHook)?.text ?? shortInfo?.hook ?? ""
    }

    func setHookText(_ text: String) {
        if let i = texts.firstIndex(where: \.isHook) {
            texts[i].text = text
        } else if !text.isEmpty {
            var style = shortStyle
            style.hookEnabled = true
            var t = texts, s = settings
            style.apply(to: &s, texts: &t, layout: shortLayout, duration: totalDuration, hookText: text)
            texts = t
            settings = s
        }
        if var info = shortInfo, info.hook != text {
            info.hook = text
            updateShortInfo(info)
        }
    }

    /// Saves the current look as a preset and returns it.
    @discardableResult
    func saveShortStyle(named name: String) -> ShortStyle {
        var style = shortStyle
        style.id = UUID()
        style.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "My Style" : name
        var saved = ShortStyleStore.saved()
        saved.removeAll { $0.name == style.name }
        saved.append(style)
        ShortStyleStore.save(saved)
        if var info = shortInfo { info.styleName = style.name; updateShortInfo(info) }
        objectWillChange.send()
        show("Saved style “\(style.name)”")
        return style
    }

    func deleteShortStyle(_ style: ShortStyle) {
        ShortStyleStore.save(ShortStyleStore.saved().filter { $0.id != style.id })
        objectWillChange.send()
    }

    // MARK: Editing

    /// Saves a short's post text (from the original's list).
    func updateShort(_ url: URL, _ info: ShortInfo) {
        guard let i = shorts.firstIndex(where: { $0.url == url }), shorts[i].info != info else { return }
        shorts[i].info = info
        do { try ShortStore.save(info, in: url) } catch { errorMessage = "Could not save: \(error.localizedDescription)" }
    }

    /// Saves this short's post text (in the short's own window).
    func updateShortInfo(_ info: ShortInfo) {
        guard info != shortInfo else { return }
        shortInfo = info
        do { try ShortStore.save(info, in: project.url) } catch { errorMessage = "Could not save: \(error.localizedDescription)" }
    }

    /// The layout most of this project's clips use.
    var shortLayout: ShortLayout {
        let layouts = clips.filter { $0.isCard != true }.map(\.camera)
        let common = Dictionary(grouping: layouts, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        return ShortLayout(common ?? .overlay)
    }

    /// One layout for every clip (camera keyframes with their own layout go), captions moved to suit.
    func applyShortLayout(_ layout: ShortLayout) {
        clips = clips.map { clip in
            var clip = clip
            if clip.isCard != true { clip.camera = layout.cameraLayout }
            return clip
        }
        cameraKeys.removeAll()
        let y = shortStyle.captionY(layout: layout)
        if !captions.isEmpty { styleAllCaptions { $0.y = y } }
    }

    func openShort(_ entry: ShortEntry) { openProject?(entry.url) }

    func openOriginal() {
        guard let info = shortInfo else { return }
        guard FileManager.default.fileExists(atPath: info.parentURL.appendingPathComponent("project.json").path) else {
            errorMessage = "The original video “\(info.parentName)” is no longer there."
            return
        }
        openProject?(info.parentURL)
    }

    func deleteShort(_ entry: ShortEntry) {
        closeProject?(entry.url)
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            shorts.removeAll { $0.url == entry.url }
            show("Moved “\(entry.info.title)” to the Trash")
        } catch {
            errorMessage = "Could not delete: \(error.localizedDescription)"
        }
    }

    func copyPostText(_ info: ShortInfo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info.postText, forType: .string)
        show("Title, description and hashtags copied")
    }

    // MARK: Export

    /// Exports shorts to ~/Movies/<original> – Shorts/: "NN Title.mp4" plus "NN Title.txt" with the
    /// post text. In a short's own window, pass nothing to export this short.
    func exportShorts(_ entries: [ShortEntry]? = nil) {
        saveNow()
        let list: [ShortEntry]
        if let entries {
            list = entries
        } else if let info = shortInfo {
            list = [ShortEntry(url: project.url, info: info, duration: totalDuration)]
        } else {
            list = shorts
        }
        guard !list.isEmpty else { return }
        guard begin("short-export", list.count == 1 ? "Exporting “\(list[0].info.title)”…" : "Exporting \(list.count) shorts…") else { return }
        Task {
            defer { end("short-export") }
            var written: [URL] = []
            do {
                let fm = FileManager.default
                for (i, entry) in list.enumerated() {
                    var info = ShortStore.load(entry.url) ?? entry.info
                    let folder = ShortStore.exportFolder(parentName: info.parentName)
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    let base = ShortStore.exportBaseName(info)
                    let video = folder.appendingPathComponent(base + ".mp4")
                    // A renamed short replaces its earlier export instead of leaving a duplicate.
                    if let old = info.exportedPath.map(URL.init(fileURLWithPath:)), old != video,
                       old.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path {
                        try? fm.removeItem(at: old)
                        try? fm.removeItem(at: old.deletingPathExtension().appendingPathExtension("txt"))
                    }
                    let project = try ProjectStore.load(entry.url)
                    let n = Double(list.count), done = Double(i)
                    try await Exporter.export(project: project, to: video) { [weak self] p in
                        Task { @MainActor in self?.report("short-export", progress: (done + p) / n) }
                    }
                    try info.postText.write(to: folder.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
                    info.exportedPath = video.path
                    info.exportedAt = Date()
                    try ShortStore.save(info, in: entry.url)
                    written.append(video)
                }
                if let first = written.first { lastOutputFolder = first.deletingLastPathComponent() }
                reloadShorts()
                end("short-export", written.count == 1 ? "Exported \(written[0].lastPathComponent)" : "Exported \(written.count) shorts")
            } catch {
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func revealShortsFolder() {
        let folder = ShortStore.exportFolder(parentName: shortInfo?.parentName ?? name)
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            show("Nothing exported yet")
        }
    }
}
