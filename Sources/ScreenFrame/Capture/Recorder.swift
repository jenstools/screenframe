import AVFoundation
import ScreenCaptureKit

enum CaptureTarget: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// Rect in display-local points, top-left origin.
    case area(CGDirectDisplayID, CGRect)
}

struct RecordOptions {
    var target: CaptureTarget
    var systemAudio: Bool
    var microphone: Bool
    /// nil = no camera; "" = default camera.
    var cameraID: String? = nil
    var captureTyping = false
}

enum RecorderError: LocalizedError {
    case noDisplay
    case noWindow
    case noFrames
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "The selected display is no longer available."
        case .noWindow: return "The selected window is no longer open."
        case .noFrames: return "No video frames were captured."
        case .writer(let message): return "Could not write the recording: \(message)"
        }
    }
}

/// Screen capture: ScreenCaptureKit stream with the cursor hidden → HEVC .mov. System audio and
/// microphone go to their own .m4a files (each starts whenever its first sample arrives, the offset
/// is stored). The cursor is captured separately by InputSampler and drawn back in the editor.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let folder: URL
    let options: RecordOptions

    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "screenframe.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "screenframe.audio", qos: .userInteractive)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var firstVideoPTS: CMTime?
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoPTS = CMTime.zero

    private var audioWriters: [String: AudioFileWriter] = [:]
    private(set) var webcam: WebcamRecorder?
    private var sampler: InputSampler?
    private var pixelSize = CGSize.zero
    private var pointScale = 1.0
    private var cornerRadius: Double?

    /// Wired up by the app before `start()`: the camera bubble and the stop control on screen.
    var webcamFrame: (() -> CGRect?)?
    var controlsFrame: (() -> CGRect?)?
    /// Video time at which the mouse went to the stop control, if it stayed there until the stop.
    private(set) var tailCut: Double?
    /// Host times of "Take again" presses (main thread).
    private var retakeHostTimes: [Double] = []

    @MainActor
    func markRetake() {
        retakeHostTimes.append(CMClockGetTime(CMClockGetHostTimeClock()).seconds)
    }

    /// Called on an arbitrary queue when capture fails mid-recording.
    var onFailure: ((Error) -> Void)?

    init(folder: URL, options: RecordOptions) {
        self.folder = folder
        self.options = options
    }

    /// Starts the camera early (before the countdown) so its preview can be shown.
    func prepareCamera() throws {
        guard let cameraID = options.cameraID, webcam == nil else { return }
        let webcam = try WebcamRecorder(deviceID: cameraID.isEmpty ? nil : cameraID, url: folder.appendingPathComponent("webcam.mov"))
        webcam.start()
        self.webcam = webcam
    }

    func start() async throws {
        try prepareCamera()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Keep our own windows (HUD, editor) out of the recording.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }

        let filter: SCContentFilter
        let contentSize: CGSize
        var sourceRect: CGRect?
        let origin: () -> CGPoint
        switch options.target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecorderError.noDisplay }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            contentSize = filter.contentRect.size
            let bounds = CGDisplayBounds(id)
            origin = { bounds.origin }
        case .area(let id, let rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecorderError.noDisplay }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            sourceRect = rect
            contentSize = rect.size
            let bounds = CGDisplayBounds(id)
            origin = { CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY) }
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.noWindow }
            filter = SCContentFilter(desktopIndependentWindow: window)
            contentSize = window.frame.size
            let tracker = WindowTracker(windowID: id, origin: window.frame.origin)
            origin = { tracker.current() }
            cornerRadius = 12
        }

        pointScale = Double(filter.pointPixelScale)
        let width = Int(contentSize.width * CGFloat(pointScale)) & ~1
        let height = Int(contentSize.height * CGFloat(pointScale)) & ~1
        pixelSize = CGSize(width: width, height: height)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        if let sourceRect { config.sourceRect = sourceRect }
        if case .window = options.target { config.ignoreShadowsSingleWindow = true }
        if options.systemAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        if options.microphone {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("recording.mov"), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(10_000_000, width * height * 5),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writer("video input rejected") }
        writer.add(input)
        guard writer.startWriting() else { throw RecorderError.writer(writer.error?.localizedDescription ?? "startWriting failed") }
        self.writer = writer
        self.videoInput = input

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        if options.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue) }
        self.stream = stream

        let sampler = InputSampler(origin: origin, pixelScale: pointScale,
                                   cursorsDir: folder.appendingPathComponent("cursors"))
        sampler.contentSize = contentSize
        sampler.webcamFrame = webcamFrame
        sampler.controlsFrame = controlsFrame
        let webcamFrame = self.webcamFrame, controlsFrame = self.controlsFrame
        sampler.excludedFrames = { [webcamFrame?(), controlsFrame?()].compactMap { $0 } }
        self.sampler = sampler
        let typing = options.captureTyping
        await MainActor.run {
            if typing { sampler.captureTyping() }
            sampler.start()
        }
        try await stream.startCapture()
    }

    func stop() async throws -> RecordingInfo {
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        let sampler = self.sampler
        await MainActor.run { sampler?.stop() }
        try? await stream?.stopCapture()
        stream = nil

        let end: CMTime = try await withCheckedThrowingContinuation { continuation in
            videoQueue.async { [self] in
                guard let writer, let videoInput, firstVideoPTS != nil, let last = lastVideoSample else {
                    writer?.cancelWriting()
                    continuation.resume(throwing: RecorderError.noFrames)
                    return
                }
                // ScreenCaptureKit only delivers frames when something changes. Repeat the last
                // frame at the stop time so a static ending isn't cut off.
                var end = lastVideoPTS
                if stopTime > lastVideoPTS {
                    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: stopTime, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                                                          sampleTimingArray: &timing, sampleBufferOut: &copy)
                    if let copy, videoInput.isReadyForMoreMediaData, videoInput.append(copy) { end = stopTime }
                }
                lastVideoSample = nil
                videoInput.markAsFinished()
                writer.endSession(atSourceTime: end)
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: end)
                    } else {
                        continuation.resume(throwing: RecorderError.writer(writer.error?.localizedDescription ?? "finish failed"))
                    }
                }
            }
        }

        let audio: [AudioTrackInfo] = await withCheckedContinuation { continuation in
            audioQueue.async { [self] in
                let group = DispatchGroup()
                var tracks: [AudioTrackInfo] = []
                for (kind, file) in audioWriters.sorted(by: { $0.key < $1.key }) {
                    group.enter()
                    file.finish { ok in
                        self.audioQueue.async {
                            if ok, let start = file.startTime, let first = self.firstVideoPTS {
                                tracks.append(AudioTrackInfo(file: file.url.lastPathComponent, offset: (start - first).seconds, kind: kind))
                            }
                            group.leave()
                        }
                    }
                }
                group.notify(queue: audioQueue) { continuation.resume(returning: tracks.sorted { $0.kind > $1.kind }) }
            }
        }

        guard let first = firstVideoPTS else { throw RecorderError.noFrames }
        let t0 = first.seconds
        let webcamInfo = await webcam?.stop(screenStart: t0)
        let duration = (end - first).seconds
        let raw = await MainActor.run { (sampler?.mouse ?? [], sampler?.clicks ?? [], sampler?.cursors ?? []) }
        let keys = await MainActor.run { sampler?.keystrokes ?? [] }.map { $0 - t0 }.filter { $0 >= 0 }
        let retakes = await MainActor.run { retakeHostTimes }.map { $0 - t0 }.filter { $0 > 0 }
        let path = await MainActor.run { sampler?.webcamPath ?? [] }
            .map { WebcamPoint(t: max(0, $0.host - t0), x: $0.x, y: $0.y) }
        if let entered = await MainActor.run(body: { sampler?.enteredControlsAt }), entered - t0 > 0.5 {
            tailCut = entered - t0
        }
        let mouse = raw.0.map { MouseSample(t: max(0, $0.host - t0), x: $0.x, y: $0.y, c: $0.cursor) }
        let clicks = raw.1.map { ClickEvent(t: max(0, $0.host - t0), x: $0.x, y: $0.y, down: $0.down, button: $0.button) }

        return RecordingInfo(version: 1, videoFile: "recording.mov", audio: audio,
                             sourceWidth: pixelSize.width, sourceHeight: pixelSize.height, pointScale: pointScale,
                             duration: duration, mouse: mouse, clicks: clicks, cursors: raw.2, cornerRadius: cornerRadius,
                             webcam: webcamInfo, keystrokes: options.captureTyping ? keys : nil,
                             webcamPath: webcamInfo == nil || path.isEmpty ? nil : path,
                             retakeMarks: retakes.isEmpty ? nil : retakes)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: appendVideo(sampleBuffer)
        case .audio: appendAudio(sampleBuffer, kind: "system-audio")
        case .microphone: appendAudio(sampleBuffer, kind: "microphone")
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let writer, let videoInput, writer.status == .writing else { return }
        let pts = sampleBuffer.presentationTimeStamp
        if firstVideoPTS == nil {
            writer.startSession(atSourceTime: pts)
            firstVideoPTS = pts
        }
        guard pts > lastVideoPTS || lastVideoSample == nil else { return }
        if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
            lastVideoSample = sampleBuffer
            lastVideoPTS = pts
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, kind: String) {
        // Audio before the first frame has nothing to play against; drop it.
        guard firstVideoPTS != nil, let format = sampleBuffer.formatDescription else { return }
        let file: AudioFileWriter
        if let existing = audioWriters[kind] {
            file = existing
        } else {
            guard let created = AudioFileWriter(url: folder.appendingPathComponent("\(kind).m4a"), format: format) else { return }
            audioWriters[kind] = created
            file = created
        }
        file.append(sampleBuffer)
    }
}

/// One AAC file per audio source, configured from the first buffer's format.
final class AudioFileWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private(set) var startTime: CMTime?

    init?(url: URL, format: CMFormatDescription) {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return nil }
        let channels = min(2, max(1, Int(asbd.mChannelsPerFrame)))
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 96_000 * channels,
        ], sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        self.url = url
        self.writer = writer
        self.input = input
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard writer.status == .writing else { return }
        if startTime == nil {
            startTime = sampleBuffer.presentationTimeStamp
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func finish(_ done: @escaping (Bool) -> Void) {
        guard startTime != nil, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            done(false)
            return
        }
        input.markAsFinished()
        writer.finishWriting { [writer] in done(writer.status == .completed) }
    }
}
