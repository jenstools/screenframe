import AVFoundation
import Foundation

/// Converts a `.screenstudio` project (recording/ folder with per-channel media, mouse logs and
/// cursor PNGs) into a ScreenFrame project. Media files are copied; the original is untouched.
enum ScreenStudioImporter {
    enum ImportError: LocalizedError {
        case notAProject
        case noDisplayVideo

        var errorDescription: String? {
            switch self {
            case .notAProject: return "That folder isn't a Screen Studio project (no recording/metadata.json)."
            case .noDisplayVideo: return "The Screen Studio project has no screen recording."
            }
        }
    }

    static func importProject(at source: URL) async throws -> Project {
        let recording = source.appendingPathComponent("recording")
        guard let metadata = json(recording.appendingPathComponent("metadata.json")) as? [String: Any] else {
            throw ImportError.notAProject
        }
        let recorders = metadata["recorders"] as? [[String: Any]] ?? []
        let session = (metadata["sessions"] as? [[String: Any]])?.first ?? [:]
        let startMs = session["processTimeStartMs"] as? Double ?? 0

        guard let display = recorders.first(where: { ($0["type"] as? String) == "display" || ($0["type"] as? String) == "window" }),
              let displayID = display["id"] as? String else { throw ImportError.noDisplayVideo }
        let videoSource = recording.appendingPathComponent("\(displayID)-0.mp4")
        guard FileManager.default.fileExists(atPath: videoSource.path) else { throw ImportError.noDisplayVideo }

        let asset = AVURLAsset(url: videoSource)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ImportError.noDisplayVideo }
        let natural = try await track.load(.naturalSize)
        var duration = try await asset.load(.duration).seconds
        if let ms = session["durationMs"] as? Double { duration = ms / 1000 }

        // Mouse coordinates are display points; the video covers cropRect (if any) at some scale.
        let mouseMoves = json(recording.appendingPathComponent("mousemoves-0.json")) as? [[String: Any]] ?? []
        let configuration = display["configuration"] as? [String: Any] ?? [:]
        var originX = 0.0, originY = 0.0, scale = 1.0
        if let crop = configuration["cropRect"] as? [String: Any], let cropWidth = crop["width"] as? Double, cropWidth > 0 {
            originX = crop["x"] as? Double ?? 0
            originY = crop["y"] as? Double ?? 0
            scale = natural.width / cropWidth
        } else {
            let maxX = mouseMoves.compactMap { $0["x"] as? Double }.max() ?? 0
            scale = maxX > 0 && maxX * 2 <= natural.width * 1.05 ? 2 : 1
        }

        let mouse = mouseMoves.compactMap { m -> MouseSample? in
            guard let x = m["x"] as? Double, let y = m["y"] as? Double, let ms = m["processTimeMs"] as? Double else { return nil }
            return MouseSample(t: max(0, (ms - startMs) / 1000), x: (x - originX) * scale, y: (y - originY) * scale,
                               c: m["cursorId"] as? String)
        }.sorted { $0.t < $1.t }

        let clickEvents = json(recording.appendingPathComponent("mouseclicks-0.json")) as? [[String: Any]] ?? []
        let clicks = clickEvents.compactMap { c -> ClickEvent? in
            guard let x = c["x"] as? Double, let y = c["y"] as? Double, let ms = c["processTimeMs"] as? Double,
                  let type = c["type"] as? String else { return nil }
            let button: Int
            switch c["button"] as? String {
            case "left": button = 0
            case "right": button = 1
            default: button = 2
            }
            return ClickEvent(t: max(0, (ms - startMs) / 1000), x: (x - originX) * scale, y: (y - originY) * scale,
                              down: type == "mouseDown", button: button)
        }

        let folder = try ProjectStore.newProjectFolder(prefix: "Imported")
        let fm = FileManager.default
        try fm.copyItem(at: videoSource, to: folder.appendingPathComponent("recording.mp4"))

        var cursors: [CursorImageInfo] = []
        for c in json(recording.appendingPathComponent("cursors.json")) as? [[String: Any]] ?? [] {
            guard let id = c["id"] as? String else { continue }
            let png = recording.appendingPathComponent("cursors/\(id).png")
            guard fm.fileExists(atPath: png.path) else { continue }
            try? fm.copyItem(at: png, to: folder.appendingPathComponent("cursors/\(id).png"))
            let hot = c["hotSpot"] as? [String: Double] ?? [:]
            let size = c["standardSize"] as? [String: Double] ?? [:]
            cursors.append(CursorImageInfo(id: id, hotX: hot["x"] ?? 0, hotY: hot["y"] ?? 0,
                                           width: size["width"] ?? 24, height: size["height"] ?? 24))
        }

        var audio: [AudioTrackInfo] = []
        for recorder in recorders {
            guard let id = recorder["id"] as? String, let type = recorder["type"] as? String,
                  type == "systemAudio" || type == "microphone" else { continue }
            let file = recording.appendingPathComponent("\(id)-0.m4a")
            guard fm.fileExists(atPath: file.path) else { continue }
            let name = type == "systemAudio" ? "system-audio.m4a" : "microphone.m4a"
            try fm.copyItem(at: file, to: folder.appendingPathComponent(name))
            audio.append(AudioTrackInfo(file: name, offset: 0, kind: type == "systemAudio" ? "system-audio" : "microphone"))
        }

        let info = RecordingInfo(version: 1, videoFile: "recording.mp4", audio: audio,
                                 sourceWidth: natural.width, sourceHeight: natural.height, pointScale: scale,
                                 duration: duration, mouse: mouse, clicks: clicks, cursors: cursors)
        let name = source.deletingPathExtension().lastPathComponent
        return try ProjectStore.finalize(folder: folder, info: info, name: name)
    }

    private static func json(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
