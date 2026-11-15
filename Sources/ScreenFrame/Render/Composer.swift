import AVFoundation
import CoreImage

/// One stretch of the timeline: a single clip, or two clips mid-transition. Carries everything
/// the compositor (which AVFoundation instantiates itself) needs to draw it.
final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    struct Layer {
        let model: RenderModel
        let screenTrack: CMPersistentTrackID
        let webcamTrack: CMPersistentTrackID?
    }

    struct Transition {
        let kind: ClipTransition.Kind
        let start: Double
        let duration: Double
    }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [Layer]
    let transition: Transition?
    let texts: TextRenderer?
    let canvas: CGSize
    /// Brand logo, already scaled, faded and positioned.
    let watermark: CIImage?
    /// Progress bar and the timeline length it measures against.
    let progress: (bar: ProgressBar, duration: Double)?

    init(timeRange: CMTimeRange, layers: [Layer], transition: Transition?, texts: TextRenderer?, canvas: CGSize,
         watermark: CIImage? = nil, progress: (bar: ProgressBar, duration: Double)? = nil) {
        self.timeRange = timeRange
        self.layers = layers
        self.transition = transition
        self.texts = texts
        self.canvas = canvas
        self.watermark = watermark
        self.progress = progress
        self.requiredSourceTrackIDs = layers.flatMap { [$0.screenTrack] + ($0.webcamTrack.map { [$0] } ?? []) }.map { NSNumber(value: $0) }
    }
}

/// Draws every output frame. Used by AVPlayer (preview), AVAssetExportSession (export) and
/// AVAssetImageGenerator (stills) alike, so all three always match.
final class FrameCompositor: NSObject, AVVideoCompositing {
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? FrameInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "ScreenFrame", code: 1, userInfo: [NSLocalizedDescriptionKey: "No render target"]))
                return
            }
            let time = request.compositionTime.seconds
            let images = instruction.layers.map { layer -> CIImage in
                let screen = request.sourceFrame(byTrackID: layer.screenTrack).map { CIImage(cvPixelBuffer: $0) }
                let webcam = layer.webcamTrack.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
                return layer.model.render(source: screen, webcam: webcam, time: time)
            }
            var image = images[0]
            if images.count == 2, let transition = instruction.transition {
                let p = min(1, max(0, (time - transition.start) / transition.duration))
                image = Self.blend(images[0], images[1], kind: transition.kind, progress: p, canvas: instruction.canvas)
            }
            if let texts = instruction.texts { image = texts.render(over: image, at: time) }
            if let watermark = instruction.watermark { image = watermark.composited(over: image) }
            if let progress = instruction.progress {
                image = Self.progressBar(progress.bar, fraction: time / max(0.01, progress.duration), canvas: instruction.canvas)
                    .composited(over: image)
            }
            Self.context.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.canvas),
                                colorSpace: Self.outputColorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private static func blend(_ outgoing: CIImage, _ incoming: CIImage, kind: ClipTransition.Kind, progress p: Double,
                              canvas: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let eased = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        switch kind {
        case .crossfade:
            return faded(incoming, eased).composited(over: outgoing)
        case .fade:
            let black = CIImage(color: .black).cropped(to: bounds)
            return p < 0.5 ? faded(outgoing, 1 - 2 * p).composited(over: black) : faded(incoming, 2 * p - 1).composited(over: black)
        case .slide:
            let shift = canvas.width * eased
            return incoming.transformed(by: CGAffineTransform(translationX: canvas.width - shift, y: 0))
                .composited(over: outgoing.transformed(by: CGAffineTransform(translationX: -shift, y: 0)))
                .cropped(to: bounds)
        }
    }

    private static func faded(_ image: CIImage, _ alpha: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, min(1, alpha)))])
    }

    /// A faint track with the played part filled (solid, or a gradient across the whole width).
    static func progressBar(_ bar: ProgressBar, fraction: Double, canvas: CGSize) -> CIImage {
        let h = max(2, (bar.height * canvas.height).rounded())
        let y = bar.atTop ? canvas.height - h : 0
        let track = CGRect(x: 0, y: y, width: canvas.width, height: h)
        let filled = CGRect(x: 0, y: y, width: (canvas.width * min(1, max(0, fraction))).rounded(), height: h)
        let colors = bar.colors.isEmpty ? [0xFFFFFF] : bar.colors
        let fill: CIImage
        if colors.count > 1 {
            fill = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: y), "inputPoint1": CIVector(x: canvas.width, y: y),
                "inputColor0": CIColor(cgColor: .hex(colors[0])), "inputColor1": CIColor(cgColor: .hex(colors[colors.count - 1])),
            ])?.outputImage ?? CIImage(color: CIColor(cgColor: .hex(colors[0])))
        } else {
            fill = CIImage(color: CIColor(cgColor: .hex(colors[0])))
        }
        return fill.cropped(to: filled)
            .composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.22)).cropped(to: track))
    }
}

struct BuiltComposition {
    let asset: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let canvas: CGSize
}

enum ComposerError: LocalizedError {
    case empty
    var errorDescription: String? { "There is nothing to play: every clip is empty or its media is missing." }
}

/// What a render shows. Export writes the final edit plus, for projects with a camera, a screen-only
/// and a camera-only version on the same timeline (same cuts, speed, transitions and audio), so the
/// three files line up frame for frame.
enum RenderVariant: String, CaseIterable {
    /// Everything: screen, camera, titles, captions, logo.
    case final
    /// The edited screen without camera, titles, captions or logo.
    case screen
    /// The camera full frame (black where a clip has no camera), without titles, captions or logo.
    case camera

    /// Suffix for the extra files next to the final export.
    var fileSuffix: String {
        switch self {
        case .final: return ""
        case .screen: return " - Screen"
        case .camera: return " - Camera"
        }
    }
}

enum Composer {
    /// Audio lanes, in display order.
    static let audioKinds = ["microphone", "system-audio", "clip-audio"]
    private static let timescale: CMTimeScale = 600

    /// The output canvas follows the first playable clip (for the "Source" aspect).
    static func canvas(for project: Project, maxLongSide: CGFloat?, resolution: ExportResolution?) -> CGSize {
        let source = project.doc.clips.lazy.compactMap { project.media(for: $0)?.sourceSize }.first
            ?? CGSize(width: project.info.sourceWidth, height: project.info.sourceHeight)
        return RenderModel.canvasSize(source: source, aspect: project.doc.settings.aspect, resolution: resolution, maxLongSide: maxLongSide)
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

    /// The brand logo scaled to its size, faded and placed in its corner.
    static func makeWatermark(_ mark: Watermark, canvas: CGSize) -> CIImage? {
        guard let logo = CIImage(contentsOf: URL(fileURLWithPath: mark.path)), logo.extent.height > 0 else { return nil }
        let height = mark.size * canvas.height
        let scale = height / logo.extent.height
        let width = logo.extent.width * scale
        let margin = min(canvas.width, canvas.height) * 0.035
        let left = mark.corner == .topLeft || mark.corner == .bottomLeft
        let bottom = mark.corner == .bottomLeft || mark.corner == .bottomRight
        let x = left ? margin : canvas.width - margin - width
        let y = bottom ? margin : canvas.height - margin - height
        return logo
            .transformed(by: CGAffineTransform(translationX: -logo.extent.minX, y: -logo.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: mark.opacity)])
    }

    /// Inserts `[sourceStart, sourceEnd)` of `source` so it plays at timeline time `at`, stretched by `speed`.
    private static func insert(_ source: AVAssetTrack, from sourceStart: Double, to sourceEnd: Double,
                               into track: AVMutableCompositionTrack, at: Double, speed: Double) throws {
        let range = CMTimeRange(start: time(sourceStart), end: time(sourceEnd))
        try track.insertTimeRange(range, of: source, at: time(at))
        if abs(speed - 1) > 0.001 {
            track.scaleTimeRange(CMTimeRange(start: time(at), duration: range.duration), toDuration: time((sourceEnd - sourceStart) / speed))
        }
    }

    /// All clips on alternating A/B tracks (so transitions can overlap), one A/B pair per audio lane
    /// and for the webcam, and a video composition with one instruction per stretch of timeline.
    static func build(project: Project, maxLongSide: CGFloat?, resolution: ExportResolution?,
                      variant: RenderVariant = .final) async throws -> BuiltComposition {
        var settings = project.doc.settings
        if variant == .screen { settings.showCamera = false }
        let canvas = canvas(for: project, maxLongSide: maxLongSide, resolution: resolution)
        let texts = TextRenderer(texts: variant == .final ? project.doc.texts : [], canvas: canvas)
        let placements = TimelineLayout.place(project.doc.clips, in: project)
        guard !placements.isEmpty else { throw ComposerError.empty }

        let composition = AVMutableComposition()
        func newTrack(_ type: AVMediaType) -> AVMutableCompositionTrack? {
            composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        var screenTracks: [Int: AVMutableCompositionTrack] = [:]
        var webcamTracks: [Int: AVMutableCompositionTrack] = [:]
        var audioTracks: [String: AVMutableCompositionTrack] = [:]   // "kind/ab"
        struct VolumeEvent { let at: Double; let fadeIn: Double; let fadeOut: Double; let end: Double; let volume: Float }
        var volumeEvents: [String: [VolumeEvent]] = [:]
        var layers: [FrameInstruction.Layer?] = []

        for (k, p) in placements.enumerated() {
            let ab = k % 2
            let media = p.media
            let asset = AVURLAsset(url: media.videoURL)
            guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
                  let videoRange = try? await videoTrack.load(.timeRange) else {
                layers.append(nil)
                continue
            }
            let start = p.clip.start
            let end = min(p.clip.end, videoRange.end.seconds)
            if screenTracks[ab] == nil { screenTracks[ab] = newTrack(.video) }
            guard let screen = screenTracks[ab] else { layers.append(nil); continue }
            if end - start > 0.02 { try insert(videoTrack, from: start, to: end, into: screen, at: p.offset, speed: p.speed) }

            var webcamTrackID: CMPersistentTrackID?
            if variant != .screen, let webcam = media.info.webcam {
                let camAsset = AVURLAsset(url: media.folder.appendingPathComponent(webcam.file))
                if let source = try? await camAsset.loadTracks(withMediaType: .video).first,
                   let camRange = try? await source.load(.timeRange) {
                    let s0 = max(0, start - webcam.offset), s1 = min(camRange.end.seconds, end - webcam.offset)
                    if s1 > s0 + 0.02 {
                        if webcamTracks[ab] == nil { webcamTracks[ab] = newTrack(.video) }
                        if let track = webcamTracks[ab] {
                            try? insert(source, from: s0, to: s1, into: track, at: p.timelineTime(s0 + webcam.offset), speed: p.speed)
                            webcamTrackID = track.trackID
                        }
                    }
                }
            }

            for audio in media.info.audio {
                let audioAsset = AVURLAsset(url: media.folder.appendingPathComponent(audio.file))
                guard let source = try? await audioAsset.loadTracks(withMediaType: .audio).first,
                      let audioRange = try? await source.load(.timeRange) else { continue }
                // Audio file time 0 plays at source-video time `offset`.
                let s0 = max(0, start - audio.offset), s1 = min(audioRange.end.seconds, end - audio.offset)
                guard s1 > s0 + 0.01 else { continue }
                let key = "\(audio.kind)/\(ab)"
                if audioTracks[key] == nil { audioTracks[key] = newTrack(.audio) }
                guard let track = audioTracks[key] else { continue }
                try? insert(source, from: s0, to: s1, into: track, at: p.timelineTime(s0 + audio.offset), speed: p.speed)
                let volume = settings.volume(for: audio.kind) * Float(p.clip.volume(for: audio.kind))
                volumeEvents[key, default: []].append(VolumeEvent(at: p.offset, fadeIn: p.overlapIn, fadeOut: p.overlapOut,
                                                                  end: p.end, volume: volume))
            }

            let model = RenderModel(media: media, settings: settings, clip: p.clip, canvas: canvas,
                                    clipStart: start, clipOffset: p.offset, cameraKeys: project.doc.cameraKeys,
                                    blurs: project.doc.blurs, preview: maxLongSide != nil, cameraOnly: variant == .camera)
            layers.append(FrameInstruction.Layer(model: model, screenTrack: screen.trackID, webcamTrack: webcamTrackID))
        }

        // Instructions: [start + overlapIn, end - overlapOut] shows one clip, the overlap shows both.
        // Boundaries are computed once as CMTime so neighbouring ranges meet exactly.
        let totalEnd = max(composition.duration, time(placements.last!.end))
        var instructions: [FrameInstruction] = []
        var cursor = CMTime.zero
        let textRenderer = texts.isEmpty ? nil : texts
        let watermark = variant == .final ? settings.watermark.flatMap { makeWatermark($0, canvas: canvas) } : nil
        let progress = variant == .final ? settings.progressBar.map { (bar: $0, duration: TimelineLayout.duration(of: project)) } : nil
        for (k, p) in placements.enumerated() {
            guard let layer = layers[k] else { continue }
            let soloEnd = k == placements.count - 1 ? totalEnd : time(p.end - p.overlapOut)
            if soloEnd > cursor {
                instructions.append(FrameInstruction(timeRange: CMTimeRange(start: cursor, end: soloEnd), layers: [layer],
                                                     transition: nil, texts: textRenderer, canvas: canvas,
                                                     watermark: p.clip.isCard == true ? nil : watermark, progress: progress))
                cursor = soloEnd
            }
            if p.overlapOut > 0, k + 1 < placements.count, let next = layers[k + 1], let kind = p.clip.transition?.kind {
                let overlapEnd = time(p.end)
                if overlapEnd > cursor {
                    instructions.append(FrameInstruction(
                        timeRange: CMTimeRange(start: cursor, end: overlapEnd), layers: [layer, next],
                        transition: .init(kind: kind, start: cursor.seconds, duration: overlapEnd.seconds - cursor.seconds),
                        texts: textRenderer, canvas: canvas, watermark: watermark, progress: progress))
                    cursor = overlapEnd
                }
            }
        }
        guard !instructions.isEmpty else { throw ComposerError.empty }
        if cursor < totalEnd, let last = instructions.last {
            instructions[instructions.count - 1] = FrameInstruction(timeRange: CMTimeRange(start: last.timeRange.start, end: totalEnd),
                                                                    layers: last.layers, transition: last.transition,
                                                                    texts: last.texts, canvas: canvas, watermark: watermark,
                                                                    progress: progress)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = FrameCompositor.self
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = instructions

        // Per-clip volume, with fades across transitions.
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioTracks.map { key, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTimePitchAlgorithm = .spectral
            for event in (volumeEvents[key] ?? []).sorted(by: { $0.at < $1.at }) {
                if event.fadeIn > 0 {
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: event.volume,
                                             timeRange: CMTimeRange(start: time(event.at), duration: time(event.fadeIn)))
                } else {
                    parameters.setVolume(event.volume, at: time(event.at))
                }
                if event.fadeOut > 0 {
                    parameters.setVolumeRamp(fromStartVolume: event.volume, toEndVolume: 0,
                                             timeRange: CMTimeRange(start: time(event.end - event.fadeOut), duration: time(event.fadeOut)))
                }
            }
            return parameters
        }
        return BuiltComposition(asset: composition, videoComposition: videoComposition, audioMix: audioMix, canvas: canvas)
    }
}

enum Exporter {
    /// Where a variant goes next to the final file: "Demo.mp4" → "Demo - Screen.mp4".
    static func url(for variant: RenderVariant, final url: URL) -> URL {
        guard variant != .final else { return url }
        let base = url.deletingPathExtension().lastPathComponent + variant.fileSuffix
        return url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(url.pathExtension)
    }

    /// The variants an export writes: the final edit, plus screen and camera when `parts` is on and
    /// the project has a camera.
    static func variants(for project: Project, parts: Bool) -> [RenderVariant] {
        parts && project.hasCamera ? [.final, .screen, .camera] : [.final]
    }

    /// Exports each variant in turn; progress runs 0…1 over all of them. Returns the written files.
    @discardableResult
    static func exportAll(project: Project, to url: URL, parts: Bool,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let variants = variants(for: project, parts: parts)
        var written: [URL] = []
        for (i, variant) in variants.enumerated() {
            let target = self.url(for: variant, final: url)
            let n = Double(variants.count), base = Double(i)
            try await export(project: project, to: target, variant: variant) { p in progress((base + p) / n) }
            written.append(target)
        }
        return written
    }

    static func export(project: Project, to url: URL, variant: RenderVariant = .final,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let built = try await Composer.build(project: project, maxLongSide: nil, resolution: project.doc.settings.exportResolution,
                                             variant: variant)
        guard let session = AVAssetExportSession(asset: built.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "ScreenFrame", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export is not available"])
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral
        try? FileManager.default.removeItem(at: url)
        let monitor = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: .mp4)
        progress(1)
    }

    /// One rendered still at timeline time `t`, for thumbnails and headless checks.
    static func still(project: Project, at t: Double, maxLongSide: CGFloat? = nil) async throws -> CGImage {
        let built = try await Composer.build(project: project, maxLongSide: maxLongSide, resolution: nil)
        let generator = AVAssetImageGenerator(asset: built.asset)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let duration = try await built.asset.load(.duration).seconds
        let time = CMTime(seconds: min(max(0, t), max(0, duration - 0.02)), preferredTimescale: 600)
        return try await generator.image(at: time).image
    }
}
