import AVFoundation
import Foundation

/// A project is a plain folder:
///
///     <name>/
///       recording.json     RecordingInfo of the project's own recording (immutable)
///       project.json       ProjectDoc (editor state: clips, texts, settings)
///       recording.mov      screen video, no cursor
///       system-audio.m4a   optional
///       microphone.m4a     optional
///       cursors/<id>.png   captured cursor images
///       clips/<uuid>/      other recordings added as clips (same layout, no project.json)
///       media/<uuid>.mp4   video files added as clips
struct Project {
    let url: URL
    var info: RecordingInfo
    var doc: ProjectDoc

    func save() throws {
        try ProjectStore.write(doc, to: url.appendingPathComponent("project.json"))
    }

    /// The files and raw data behind a clip, or nil if they are missing.
    func media(for clip: Clip) -> ClipMedia? {
        switch clip.kind {
        case .recording:
            if clip.source == "." { return ClipMedia(folder: url, info: info, kind: .recording) }
            let folder = url.appendingPathComponent(clip.source, isDirectory: true)
            guard let info = MediaCache.recording(at: folder) else { return nil }
            return ClipMedia(folder: folder, info: info, kind: .recording)
        case .video:
            let file = url.appendingPathComponent(clip.source)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let info = RecordingInfo(version: 1, videoFile: file.lastPathComponent,
                                     audio: [AudioTrackInfo(file: file.lastPathComponent, offset: 0, kind: "clip-audio")],
                                     sourceWidth: clip.width ?? 1920, sourceHeight: clip.height ?? 1080, pointScale: 1,
                                     duration: clip.sourceDuration ?? clip.end, mouse: [], clicks: [], cursors: [])
            return ClipMedia(folder: file.deletingLastPathComponent(), info: info, kind: .video)
        }
    }

    var totalDuration: Double { TimelineLayout.duration(of: self) }
}

struct ClipMedia {
    let folder: URL
    let info: RecordingInfo
    let kind: Clip.Kind

    var videoURL: URL { folder.appendingPathComponent(info.videoFile) }
    var cursorsURL: URL { folder.appendingPathComponent("cursors") }
    var sourceSize: CGSize { CGSize(width: info.sourceWidth, height: info.sourceHeight) }
}

/// recording.json files of added clips, read once.
enum MediaCache {
    private static var recordings: [String: RecordingInfo] = [:]
    private static let lock = NSLock()

    static func recording(at folder: URL) -> RecordingInfo? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = recordings[folder.path] { return cached }
        guard let info = try? ProjectStore.read(RecordingInfo.self, from: folder.appendingPathComponent("recording.json")) else { return nil }
        recordings[folder.path] = info
        return info
    }
}

enum ProjectStore {
    static var root: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ScreenFrame Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newProjectFolder(prefix: String = "Recording") throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var url = root.appendingPathComponent("\(prefix) \(f.string(from: Date()))", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(prefix) \(f.string(from: Date())) \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("cursors"), withIntermediateDirectories: true)
        return url
    }

    static func load(_ url: URL) throws -> Project {
        let info = try read(RecordingInfo.self, from: url.appendingPathComponent("recording.json"))
        let docURL = url.appendingPathComponent("project.json")
        var doc = FileManager.default.fileExists(atPath: docURL.path)
            ? try read(ProjectDoc.self, from: docURL)
            : makeDoc(name: url.lastPathComponent, info: info)
        if doc.clips.isEmpty {
            // Single-recording project from before clips existed: its trim and zooms become clip 1.
            let end = doc.settings.trimEnd > doc.settings.trimStart ? min(doc.settings.trimEnd, info.duration) : info.duration
            doc.clips = [Clip(kind: .recording, source: ".", name: "Recording", start: min(doc.settings.trimStart, end),
                              end: end, zooms: doc.legacyZooms)]
            doc.settings.trimStart = 0
            doc.settings.trimEnd = 0
        }
        return Project(url: url, info: info, doc: doc)
    }

    /// Writes recording.json plus a fresh project.json with auto-generated zooms.
    @discardableResult
    static func finalize(folder: URL, info: RecordingInfo, name: String? = nil, clipEnd: Double? = nil,
                         cuts: [ClosedRange<Double>] = []) throws -> Project {
        try write(info, to: folder.appendingPathComponent("recording.json"))
        var doc = makeDoc(name: name ?? folder.lastPathComponent, info: info)
        if let clipEnd, clipEnd > 0.5, clipEnd < info.duration { doc.clips[0].end = clipEnd }
        var project = Project(url: folder, info: info, doc: doc)
        if !cuts.isEmpty {
            let content = EditOps.remove(cuts, from: EditContent(clips: doc.clips, texts: doc.texts, cameraKeys: doc.cameraKeys),
                                         project: project)
            project.doc.clips = content.clips
        }
        try project.save()
        return project
    }

    static func makeDoc(name: String, info: RecordingInfo) -> ProjectDoc {
        let settings = EditSettings()
        let clip = Clip(kind: .recording, source: ".", name: "Recording", start: 0, end: info.duration,
                        zooms: AutoZoom.generate(info: info, zoom: settings.zoomLevel))
        return ProjectDoc(name: name, createdAt: Date(), settings: settings, clips: [clip])
    }

    // MARK: New project from video files

    /// A project from existing video files instead of a recording: the first becomes the
    /// project's own recording (its audio as the voice lane), the others are added as clips.
    static func createProject(fromVideos urls: [URL]) async throws -> Project {
        guard let first = urls.first else { throw ClipImportError.unsupported("") }
        let asset = AVURLAsset(url: first)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.unsupported(first.lastPathComponent)
        }
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let duration = try await asset.load(.duration).seconds
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty

        let name = first.deletingPathExtension().lastPathComponent
        let folder = try newProjectFolder(prefix: name)
        let file = "recording.\(first.pathExtension.isEmpty ? "mov" : first.pathExtension.lowercased())"
        try FileManager.default.copyItem(at: first, to: folder.appendingPathComponent(file))
        let info = RecordingInfo(version: 1, videoFile: file,
                                 audio: hasAudio ? [AudioTrackInfo(file: file, offset: 0, kind: "clip-audio")] : [],
                                 sourceWidth: abs(size.width), sourceHeight: abs(size.height), pointScale: 1,
                                 duration: duration, mouse: [], clicks: [], cursors: [])
        var project = try finalize(folder: folder, info: info, name: name)
        project.doc.clips[0].name = name
        for url in urls.dropFirst() {
            project.doc.clips.append(try await importClip(from: url, into: project))
        }
        try project.save()
        return project
    }

    // MARK: Adding clips

    enum ClipImportError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            if case .unsupported(let name) = self { return "“\(name)” is neither a ScreenFrame recording nor a video file." }
            return nil
        }
    }

    /// Copies a ScreenFrame project folder or a video file into the project and returns the clip
    /// that plays it. Recordings keep their cursor data and bring their zooms along.
    static func importClip(from source: URL, into project: Project) async throws -> Clip {
        let fm = FileManager.default
        let id = UUID()
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            guard let info = try? read(RecordingInfo.self, from: source.appendingPathComponent("recording.json")) else {
                throw ClipImportError.unsupported(source.lastPathComponent)
            }
            let relative = "clips/\(id.uuidString)"
            let destination = project.url.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(atPath: source.path)
            where item != "project.json" && item != "clips" && item != "media" && !item.hasPrefix(".") {
                try fm.copyItem(at: source.appendingPathComponent(item), to: destination.appendingPathComponent(item))
            }
            let sourceDoc = try? load(source).doc
            let original = sourceDoc?.clips.first { $0.source == "." }
            return Clip(kind: .recording, source: relative, name: sourceDoc?.name ?? source.lastPathComponent,
                        start: original?.start ?? 0, end: original?.end ?? info.duration,
                        zooms: original?.zooms ?? AutoZoom.generate(info: info, zoom: project.doc.settings.zoomLevel))
        }

        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.unsupported(source.lastPathComponent)
        }
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let duration = try await asset.load(.duration).seconds
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let relative = "media/\(id.uuidString).\(ext)"
        try fm.createDirectory(at: project.url.appendingPathComponent("media"), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: project.url.appendingPathComponent(relative))
        return Clip(kind: .video, source: relative, name: source.deletingPathExtension().lastPathComponent,
                    start: 0, end: duration, width: abs(size.width), height: abs(size.height), sourceDuration: duration)
    }

    // MARK: Listing

    struct Summary: Identifiable {
        var id: URL { url }
        let url: URL
        let name: String
        let duration: Double
        let created: Date
    }

    static func list() -> [Summary] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return items.compactMap { url -> Summary? in
            guard let project = try? load(url) else { return nil }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Summary(url: url, name: project.doc.name, duration: project.totalDuration, created: created)
        }
        .sorted { $0.created > $1.created }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
