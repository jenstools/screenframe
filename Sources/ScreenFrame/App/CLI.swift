import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Headless entry points, used for testing the pipeline and for scripting:
///
///     ScreenFrame --import <x.screenstudio>
///     ScreenFrame --still  <project> <seconds> <out.png> [key=value ...]
///     ScreenFrame --export <project> <out.mp4> [parts=1] [key=value ...]
///     ScreenFrame --record <seconds> [window=<id>|area=x,y,w,h] [system-audio]
///     ScreenFrame --add-clip <project> <video file or recording folder>
///     ScreenFrame --list-windows
///     ScreenFrame --transcribe <audio or video file> [language]
///     ScreenFrame --faces <camera video>
///     ScreenFrame --privacy <project>            scan and save blur regions
///     ScreenFrame --pauses <project> [apply]
///     ScreenFrame --ai <project> "<request>"     edit by prompt (saved)
///     ScreenFrame --shorts <project> [count] [length=quick|standard|long] [layout=split|bubble|camera|screen] [lang=de-DE]
///     ScreenFrame --export-shorts <project>
///     ScreenFrame --short-style <short or video> <style name>
///
/// key=value overrides EditSettings fields, e.g. `aspect=square background=sunset zoomLevel=2`.
enum CLI {
    static func handles(_ arguments: [String]) -> Bool {
        guard let first = arguments.dropFirst().first else { return false }
        return ["--import", "--still", "--export", "--record", "--add-clip", "--list-windows", "--transcribe", "--faces", "--privacy", "--pauses", "--ai", "--short", "--shorts", "--export-shorts", "--short-style", "--brand", "--content", "--thumbs", "--guide", "--cut-words", "--retakes", "--from-video", "--subs"].contains(first)
    }

    static func run(_ arguments: [String]) -> Never {
        Task {
            do {
                try await execute(Array(arguments.dropFirst()))
                exit(0)
            } catch {
                FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func execute(_ args: [String]) async throws {
        switch args.first {
        case "--import":
            let project = try await ScreenStudioImporter.importProject(at: URL(fileURLWithPath: args[1]))
            print(project.url.path)
            print("duration \(String(format: "%.2f", project.info.duration))s, \(project.info.mouse.count) mouse samples, "
                  + "\(project.info.clicks.count) clicks, \(project.doc.clips.first?.zooms.count ?? 0) auto zooms")
        case "--still":
            var project = try ProjectStore.load(URL(fileURLWithPath: args[1]))
            project.doc.settings = try overrides(project.doc.settings, Array(args.dropFirst(4)))
            let image = try await Exporter.still(project: project, at: Double(args[2]) ?? 0)
            try writePNG(image, to: URL(fileURLWithPath: args[3]))
            print("\(image.width)x\(image.height) → \(args[3])")
        case "--export":
            var project = try ProjectStore.load(URL(fileURLWithPath: args[1]))
            // parts=1 also writes "<name> - Screen.mp4" and "<name> - Camera.mp4" (projects with a camera).
            let extra = Array(args.dropFirst(3))
            let parts = extra.contains { $0 == "parts=1" || $0 == "parts=true" }
            project.doc.settings = try overrides(project.doc.settings, extra.filter { !$0.hasPrefix("parts=") })
            let started = Date()
            let files = try await Exporter.exportAll(project: project, to: URL(fileURLWithPath: args[2]), parts: parts) { p in
                FileHandle.standardError.write(String(format: "\r%3.0f%%", p * 100).data(using: .utf8)!)
            }
            print(String(format: "\nexported in %.1fs", Date().timeIntervalSince(started)))
            for file in files { print("→ \(file.path)") }
        case "--record":
            let seconds = Double(args.count > 1 ? args[1] : "3") ?? 3
            var target = CaptureTarget.display(CGMainDisplayID())
            for arg in args.dropFirst(2) {
                if arg.hasPrefix("window="), let id = UInt32(arg.dropFirst(7)) { target = .window(id) }
                if arg.hasPrefix("area=") {
                    let v = arg.dropFirst(5).split(separator: ",").compactMap { Double($0) }
                    if v.count == 4 { target = .area(CGMainDisplayID(), CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) }
                }
            }
            let folder = try ProjectStore.newProjectFolder()
            let camera = args.first { $0.hasPrefix("camera=") }.map { String($0.dropFirst(7)) }
            let recorder = Recorder(folder: folder, options: RecordOptions(target: target, systemAudio: args.contains("system-audio"),
                                                                           microphone: false, cameraID: camera))
            try await recorder.start()
            try await Task.sleep(for: .seconds(seconds))
            let info = try await recorder.stop()
            try ProjectStore.finalize(folder: folder, info: info)
            print(folder.path)
            print(String(format: "%.0fx%.0f @%.0fx, %.2fs, %d mouse samples, %d cursors, audio: %@", info.sourceWidth,
                         info.sourceHeight, info.pointScale, info.duration, info.mouse.count, info.cursors.count,
                         info.audio.map(\.kind).joined(separator: ",")))
        case "--add-clip":
            var project = try ProjectStore.load(URL(fileURLWithPath: args[1]))
            let clip = try await ProjectStore.importClip(from: URL(fileURLWithPath: args[2]), into: project)
            project.doc.clips.append(clip)
            try project.save()
            print("added \(clip.kind.rawValue) clip “\(clip.name)” (\(String(format: "%.2f", clip.duration))s), total \(String(format: "%.2f", project.totalDuration))s")
        case "--from-video":
            let project = try await ProjectStore.createProject(fromVideos: args.dropFirst().map { URL(fileURLWithPath: $0) })
            print(project.url.path)
            print(String(format: "%d clips, %.2fs, audio: %@", project.doc.clips.count, project.totalDuration,
                         project.info.audio.map(\.kind).joined(separator: ",")))
        case "--retakes":
            var project = try ProjectStore.load(URL(fileURLWithPath: args[1]))
            project.info.retakeMarks = args.dropFirst(2).compactMap(Double.init)
            for cut in await Retakes.cuts(for: project.info, folder: project.url) {
                print(String(format: "retake cut %.2f – %.2f", cut.lowerBound, cut.upperBound))
            }
        case "--transcribe":
            let words = try await Captioner.words(in: URL(fileURLWithPath: args[1]), language: args.count > 2 ? args[2] : "de-DE") { _ in }
            if ProcessInfo.processInfo.environment["SF_WORDS"] != nil { print(words.prefix(12).map { "[\($0.text)]" }.joined(separator: " ")) }
            for line in Captioner.lines(from: words) {
                print(String(format: "%6.2f – %6.2f  %@", line.start, line.end, line.text))
            }
        case "--faces":
            let points = try await FaceTracker.track(URL(fileURLWithPath: args[1])) { _ in }
            print("\(points.count) face samples; first: \(points.first.map { String(format: "x %.2f y %.2f size %.2f", $0.x, $0.y, $0.size) } ?? "none")")
        case "--privacy":
            var project = try ProjectStore.load(URL(fileURLWithPath: args[1]))
            var found: [BlurRegion] = []
            var seen = Set<String>()
            for clip in project.doc.clips where seen.insert(clip.source).inserted {
                guard let media = project.media(for: clip) else { continue }
                found += try await PrivacyScanner.scan(media: media, source: clip.source) { _ in }
            }
            project.doc.blurs = project.doc.blurs.filter { $0.kind == .manual } + found
            try project.save()
            for kind in BlurRegion.Kind.allCases {
                let list = found.filter { $0.kind == kind }
                if !list.isEmpty { print("\(kind.label): \(list.count)") }
            }
        case "--pauses", "--ai", "--short", "--shorts", "--export-shorts", "--short-style", "--brand", "--content", "--thumbs", "--guide", "--cut-words", "--subs":
            try await MainActor.run { try runEditorCommand(args) }
            // The editor commands finish asynchronously; wait for them to report back.
            while !CLI.done { try await Task.sleep(for: .milliseconds(200)) }
        case "--list-windows":
            for window in try await SCShareableContent.current.windows where window.isOnScreen && window.windowLayer == 0 {
                print(window.windowID, window.owningApplication?.applicationName ?? "?", "—", window.title ?? "", window.frame)
            }
        default:
            break
        }
    }

    nonisolated(unsafe) static var done = false

    /// Runs an editor feature on a project headlessly (same code path as the buttons).
    @MainActor
    private static func runEditorCommand(_ args: [String]) throws {
        let project = try ProjectStore.load(URL(fileURLWithPath: args[1]))
        let model = EditorModel(project: project)
        model.openProject = { url in print("created \(url.path)") }
        Task { @MainActor in
            // Waveforms load in the background.
            try? await Task.sleep(for: .seconds(2))
            switch args[0] {
            case "--pauses":
                model.findSilences()
                for cut in model.cutSuggestions { print(String(format: "%6.2f – %6.2f  %@", cut.start, cut.end, cut.reason)) }
                let before = model.totalDuration
                if args.count > 2, args[2] == "apply" {
                    model.applyCuts()
                    print(String(format: "duration %.2f → %.2f", before, model.totalDuration))
                }
            case "--ai":
                model.aiPrompt = args.count > 2 ? args[2] : ""
                model.runAIPrompt()
                try? await Task.sleep(for: .milliseconds(100))
                while model.aiBusy { try? await Task.sleep(for: .milliseconds(200)) }
                print(model.aiStatus ?? model.errorMessage ?? "(no status)")
            case "--brand":
                model.applyBrandKit(model.brandKits[0])
                try? await Task.sleep(for: .milliseconds(100))
                while model.applyingBrand { try? await Task.sleep(for: .milliseconds(200)) }
                print(model.analysisStatus ?? "", "clips:", model.clips.map(\.name), "texts:", model.texts.map(\.text))
            case "--content":
                model.generateContentPackage()
                try? await Task.sleep(for: .milliseconds(100))
                while model.contentBusy { try? await Task.sleep(for: .milliseconds(200)) }
                if let p = model.contentPackage { print(ContentPackager.markdown(p, name: model.name)) }
                print("saved:", model.lastOutputFolder?.path ?? "-")
            case "--thumbs":
                let candidates = try? await ThumbnailMaker.candidates(project: model.snapshot)
                print("candidates:", candidates?.map { String(format: "%.1fs (%.2f)", $0.time, $0.score) } ?? [])
                let headline = await model.suggestHeadline()
                print("headline:", headline)
                if let t = candidates?.first?.time {
                    model.exportThumbnails(at: t, headline: headline, kit: model.brandKits.first, faceCutout: true)
                    try? await Task.sleep(for: .milliseconds(100))
                    while model.thumbnailBusy { try? await Task.sleep(for: .milliseconds(200)) }
                    print("saved:", model.lastOutputFolder?.path ?? "-")
                }
            case "--guide":
                model.buildGuide()
                try? await Task.sleep(for: .milliseconds(100))
                while model.guideProgress != nil { try? await Task.sleep(for: .milliseconds(200)) }
                print(model.analysisStatus ?? "", model.lastOutputFolder?.path ?? "-")
            case "--cut-words":
                try? await model.ensureWords()
                let words = model.transcriptWords
                print("words:", words.prefix(12).map(\.text).joined(separator: " "))
                let before = model.totalDuration
                if words.count > 6 {
                    model.transcriptSelection = 2...4
                    print("cutting:", words[2...4].map(\.text).joined(separator: " "))
                    model.cutTranscriptSelection()
                }
                print(String(format: "duration %.2f → %.2f", before, model.totalDuration))
                print("now:", model.transcriptWords.prefix(10).map(\.text).joined(separator: " "))
            case "--subs":
                model.generateCaptions()
                try? await Task.sleep(for: .milliseconds(200))
                while model.isRunning("captions") { try? await Task.sleep(for: .milliseconds(200)) }
                print("— generated (with glossary):")
                model.sortedCaptions.forEach { print("  ", $0.text) }
                if args.count > 2, args[2] == "claude" {
                    model.fixSubtitlesWithClaude()
                    try? await Task.sleep(for: .milliseconds(200))
                    while model.isRunning("subfix") { try? await Task.sleep(for: .milliseconds(200)) }
                    print("— after Fix with Claude (\(model.recentlyFixed.count) changed):")
                    model.sortedCaptions.forEach { print(model.recentlyFixed.contains($0.id) ? "  ✦" : "   ", $0.text) }
                    print("— would learn:", model.learnableFixes.map { "\($0.heard) → \($0.term)" })
                }
            case "--short", "--shorts":
                var count: Int? = args[0] == "--short" ? 1 : nil
                var length = ShortsPlanner.Length.standard
                var layout = ShortLayout.split
                for arg in args.dropFirst(2) {
                    if let n = Int(arg) { count = n }
                    if arg.hasPrefix("length="), let l = ShortsPlanner.Length(rawValue: String(arg.dropFirst(7))) { length = l }
                    if arg.hasPrefix("layout="), let l = ShortLayout(rawValue: String(arg.dropFirst(7))) { layout = l }
                    if arg.hasPrefix("lang=") { model.captionLanguage = String(arg.dropFirst(5)) }
                }
                model.makeShorts(count: count, length: length, layout: layout)
                try? await Task.sleep(for: .milliseconds(100))
                while model.shortsBusy || model.isRunning("words") { try? await Task.sleep(for: .milliseconds(200)) }
                model.reloadShorts()
                if let error = model.errorMessage { print(error) }
                for entry in model.shorts {
                    print(String(format: "#%d  %@  (%@)  %@", entry.info.index, entry.info.title, formatDuration(entry.duration), entry.url.path))
                }
            case "--short-style":
                // Styles a short (or, given a video, all its shorts) with a preset by name.
                let name = args.count > 2 ? args[2] : ""
                if let style = model.shortStyles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    if model.isShort { model.applyShortStyle(style); model.saveNow() } else { model.applyStyleToAllShorts(style) }
                    print("applied \(style.name)")
                } else {
                    print("styles: " + model.shortStyles.map(\.name).joined(separator: ", "))
                }
            case "--export-shorts":
                model.reloadShorts()
                model.exportShorts()
                try? await Task.sleep(for: .milliseconds(100))
                while model.shortsExporting != nil { try? await Task.sleep(for: .milliseconds(200)) }
                if let error = model.errorMessage { print(error) }
                print(model.lastOutputFolder?.path ?? "(nothing exported)")
            default: break
            }
            if let error = model.errorMessage { print("error: \(error)") }
            model.teardown()
            CLI.done = true
        }
    }

    private static func overrides(_ settings: EditSettings, _ pairs: [String]) throws -> EditSettings {
        guard !pairs.isEmpty else { return settings }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if let number = Double(parts[1]) { object[parts[0]] = number }
            else if parts[1] == "true" || parts[1] == "false" { object[parts[0]] = parts[1] == "true" }
            else { object[parts[0]] = parts[1] }
        }
        return try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
