import Foundation

/// Prompt editing: the project is described to Claude as plain data (timeline, transcript,
/// zooms, texts, camera), Claude answers with a list of operations, and those are applied as one
/// undoable change.
@MainActor
enum AIEditor {
    static let systemPrompt = """
    You are the editing engine of ScreenFrame, a screen-recording editor. The user describes edits in \
    plain language (German or English). You receive the project as JSON and answer with ONLY a JSON object:
    {"summary": "<one short sentence in the user's language>", "operations": [ ... ]}

    All times are timeline seconds as given in the project JSON. Use the transcript to find moments \
    ("the part where I talk about pricing"). Never invent content. If the request is unclear or impossible, \
    return no operations and explain in the summary.

    Operations (only these):
    {"op":"cut","start":s,"end":s}                         remove a stretch
    {"op":"split","at":s}
    {"op":"speed","start":s,"end":s,"speed":0.25-4}        play a stretch faster/slower
    {"op":"zoom","start":s,"end":s,"level":1.2-3,"x":0-1,"y":0-1}   x/y optional fixed focus (screen, top-left origin); omit to follow the cursor
    {"op":"remove_zooms","start":s,"end":s}                 delete zooms overlapping a stretch (omit times for all)
    {"op":"text","start":s,"end":s,"text":"...","position":"top|center|bottom","style":"pill|shadow|plain"}
    {"op":"remove_texts","start":s,"end":s}                 titles only, not captions
    {"op":"camera","at":s,"position":"top-left|top-right|bottom-left|bottom-right|center","layout":"overlay|fullscreen|hidden"}
    {"op":"volume","lane":"voice|system|clip","volume":0-1,"start":s,"end":s}   start/end optional (whole video)
    {"op":"transition","after_clip":n,"kind":"crossfade|fade|slide|none"}   n = 1-based clip number
    {"op":"setting","key":"background|aspect|padding|cornerRadius|cursorScale|zoomLevel|motionBlur|showCursor|autoZoom|showCamera|cameraShape|cameraSize|reframe","value":...}
        background: aurora|sunset|ocean|candy|forest|peach|lime|midnight|graphite|paper|wallpaper
        aspect: source|wide|square|vertical|classic   cameraShape: circle|rounded|wide
    {"op":"remove_silences"}                                cut long pauses (keeps silent screen demos)
    {"op":"captions","language":"de-DE|en-US|..."}         generate subtitles
    {"op":"blur_sensitive"}                                 blur emails, names, keys, faces
    """

    static func prompt(for model: EditorModel, request: String) -> String {
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        let placements = model.placements
        var project: [String: Any] = [
            "duration": r(model.totalDuration),
            "playhead": r(model.currentTime),
            "clips": placements.enumerated().map { i, p in
                ["number": i + 1, "name": p.clip.name, "start": r(p.offset), "end": r(p.end), "speed": p.speed,
                 "type": p.clip.kind.rawValue, "camera": p.media.info.webcam != nil] as [String: Any]
            },
            "zooms": model.placedZooms.map { ["start": r($0.start), "end": r($0.end), "level": $0.segment.zoom] },
            "texts": model.titles.map { ["start": r($0.start), "end": r($0.end), "text": $0.text] },
            "captions": model.captions.count,
            "camera_keyframes": model.cameraKeys.map { ["at": r($0.t), "layout": ($0.layout ?? .overlay).rawValue] },
            "audio_lanes": model.audioLanes.map { EditorModel.laneName($0) },
            "clicks": model.placements.flatMap { p in
                p.media.info.clicks.filter { $0.down && $0.t >= p.clip.start && $0.t < p.clip.end }.map { r(p.timelineTime($0.t)) }
            },
            "settings": ["background": model.settings.background, "aspect": model.settings.aspect.rawValue,
                         "zoomLevel": model.settings.zoomLevel, "autoZoom": model.settings.autoZoom],
        ]
        project["transcript"] = model.transcriptLines().map { "[\(r($0.start))–\(r($0.end))] \($0.text)" }
        let data = (try? JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return "Project:\n" + (String(data: data, encoding: .utf8) ?? "{}") + "\n\nRequest: " + request
    }

    static let shortSystemPrompt = """
    You pick the best moment of a screen recording for a vertical social video (LinkedIn, Reels, Shorts). \
    Choose 1–3 stretches from the transcript, 30–60 seconds in total, that work on their own: a clear hook \
    in the first seconds, one idea, a natural ending. Also write a punchy title (max 6 words, the language \
    of the transcript). Answer with ONLY JSON: {"title": "...", "ranges": [{"start": s, "end": s}]}
    """

    static func shortPrompt(lines: [Captioner.Word], duration: Double) -> String {
        "Duration: \(Int(duration)) s\nTranscript (timeline seconds):\n"
            + lines.map { String(format: "[%.1f–%.1f] %@", $0.start, $0.end, $0.text) }.joined(separator: "\n")
    }

    nonisolated static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Applies operations: non-structural ones first (on the original times), then speed changes
    /// and cuts from the end backwards so earlier times stay valid; timeline items move along.
    static func apply(_ operations: [[String: Any]], to model: EditorModel) async -> [String] {
        var applied: [String] = []
        var structural: [(start: Double, run: () -> Void)] = []
        func t(_ v: Double) -> String { formatTime(v) }

        for op in operations {
            let kind = op["op"] as? String ?? ""
            let start = number(op["start"]), end = number(op["end"])
            switch kind {
            case "cut":
                guard let a = start, let b = end, b > a else { continue }
                structural.append((a, { model.content = EditOps.remove([a...b], from: model.content, project: model.snapshot) }))
                applied.append("Cut \(t(a))–\(t(b))")
            case "speed":
                guard let a = start, let b = end, b > a, let speed = number(op["speed"]) else { continue }
                let s = min(4, max(0.25, speed))
                structural.append((a, { model.content = EditOps.setSpeed(s, from: a, to: b, in: model.content, project: model.snapshot) }))
                applied.append("\(TimelineView.speedLabel(s)) speed \(t(a))–\(t(b))")
            case "split":
                guard let at = number(op["at"]) else { continue }
                model.content = EditOps.split(model.content, at: [at], project: model.snapshot)
                applied.append("Split at \(t(at))")
            case "zoom":
                guard let a = start, let b = end, b > a, let p = model.placement(at: a) else { continue }
                let level = min(3, max(1.2, number(op["level"]) ?? model.settings.zoomLevel))
                var segment = ZoomSegment(start: p.sourceTime(a), end: p.sourceTime(min(b, p.end)), zoom: level, auto: false)
                if let x = number(op["x"]), let y = number(op["y"]) { segment.focus = CGPoint(x: x, y: y) }
                if let i = model.clips.firstIndex(where: { $0.id == p.clip.id }) { model.clips[i].zooms.append(segment) }
                model.settings.autoZoom = true
                applied.append(String(format: "Zoom %.1f× %@–%@", level, t(a), t(b)))
            case "remove_zooms":
                let a = start ?? 0, b = end ?? .infinity
                var removed = 0
                for p in model.placements {
                    guard let i = model.clips.firstIndex(where: { $0.id == p.clip.id }) else { continue }
                    let before = model.clips[i].zooms.count
                    model.clips[i].zooms.removeAll { p.timelineTime($0.end) > a && p.timelineTime($0.start) < b }
                    removed += before - model.clips[i].zooms.count
                }
                if removed > 0 { applied.append("Removed \(removed) zooms") }
            case "text":
                guard let a = start, let text = op["text"] as? String, !text.isEmpty else { continue }
                let b = max(a + 0.5, end ?? a + 3)
                let y: Double = (op["position"] as? String) == "top" ? 0.12 : (op["position"] as? String) == "center" ? 0.5 : 0.85
                let style = TextOverlay.Style(rawValue: op["style"] as? String ?? "") ?? .pill
                model.texts.append(TextOverlay(text: text, start: a, end: min(b, model.totalDuration), y: y, style: style))
                applied.append("Text “\(text.prefix(30))” at \(t(a))")
            case "remove_texts":
                let a = start ?? 0, b = end ?? .infinity
                let before = model.texts.count
                model.texts.removeAll { !$0.caption && $0.end > a && $0.start < b }
                if model.texts.count < before { applied.append("Removed \(before - model.texts.count) texts") }
            case "camera":
                let at = number(op["at"]) ?? model.currentTime
                let layout = Clip.CameraLayout(rawValue: op["layout"] as? String ?? "") ?? .overlay
                var x = model.currentCameraCenter.x, y = model.currentCameraCenter.y
                switch op["position"] as? String {
                case "top-left": (x, y) = (0.15, 0.2)
                case "top-right": (x, y) = (0.85, 0.2)
                case "bottom-left": (x, y) = (0.15, 0.8)
                case "bottom-right": (x, y) = (0.85, 0.8)
                case "center": (x, y) = (0.5, 0.5)
                default: break
                }
                model.cameraKeys.append(CameraKey(t: at, x: x, y: y, layout: layout))
                applied.append("Camera \(layout.label.lowercased()) at \(t(at))")
            case "volume":
                let lane: String
                switch op["lane"] as? String {
                case "voice": lane = "microphone"
                case "system": lane = "system-audio"
                default: lane = "clip-audio"
                }
                let volume = min(1, max(0, number(op["volume"]) ?? 1))
                if let a = start, let b = end, b > a {
                    model.content = EditOps.split(model.content, at: [a, b], project: model.snapshot)
                    for p in model.placements where p.offset >= a - 0.02 && p.end <= b + 0.02 {
                        model.setClipVolume(p.clip.id, kind: lane, volume)
                    }
                    applied.append("\(EditorModel.laneName(lane)) \(Int(volume * 100))% \(t(a))–\(t(b))")
                } else {
                    model.setVolume(lane, volume)
                    applied.append("\(EditorModel.laneName(lane)) \(Int(volume * 100))%")
                }
            case "transition":
                guard let n = number(op["after_clip"]).map(Int.init), n >= 1, n <= model.placements.count else { continue }
                let id = model.placements[n - 1].clip.id
                model.setTransition(id, ClipTransition.Kind(rawValue: op["kind"] as? String ?? ""))
                applied.append("Transition after clip \(n): \(op["kind"] as? String ?? "none")")
            case "setting":
                if let key = op["key"] as? String, applySetting(key, op["value"], to: model) { applied.append("Set \(key)") }
            case "remove_silences":
                model.findSilences()
                let count = model.cutSuggestions.count
                if count > 0 {
                    model.applyCuts()
                    applied.append("Removed \(count) pauses")
                }
            case "captions":
                if let language = op["language"] as? String { model.captionLanguage = language }
                model.generateCaptions()
                applied.append("Generating captions")
            case "blur_sensitive":
                model.scanPrivacy()
                applied.append("Scanning for sensitive info")
            default:
                continue
            }
        }
        // Later stretches first, so the times of earlier ones still point at the same content.
        for item in structural.sorted(by: { $0.start > $1.start }) { item.run() }
        return applied
    }

    private static func applySetting(_ key: String, _ value: Any?, to model: EditorModel) -> Bool {
        var s = model.settings
        let n = number(value), text = value as? String, flag = value as? Bool
        switch key {
        case "background": guard let text else { return false }; s.background = text
        case "aspect": guard let a = text.flatMap(AspectChoice.init(rawValue:)) else { return false }; s.aspect = a
        case "padding": guard let n else { return false }; s.padding = min(0.25, max(0, n > 1 ? n / 100 : n))
        case "cornerRadius": guard let n else { return false }; s.cornerRadius = min(48, max(0, n))
        case "cursorScale": guard let n else { return false }; s.cursorScale = min(3, max(0.6, n))
        case "zoomLevel": guard let n else { return false }; s.zoomLevel = min(3, max(1.2, n))
        case "motionBlur": guard let n else { return false }; s.motionBlur = min(1, max(0, n > 1 ? n / 100 : n))
        case "showCursor": guard let flag else { return false }; s.showCursor = flag
        case "autoZoom": guard let flag else { return false }; s.autoZoom = flag
        case "showCamera": guard let flag else { return false }; s.showCamera = flag
        case "cameraShape": guard let shape = text.flatMap(CameraShape.init(rawValue:)) else { return false }; s.cameraShape = shape
        case "cameraSize": guard let n else { return false }; s.cameraSize = min(0.5, max(0.12, n > 1 ? n / 100 : n))
        case "reframe": guard let flag else { return false }; s.reframe = flag
        default: return false
        }
        model.settings = s
        return true
    }
}
