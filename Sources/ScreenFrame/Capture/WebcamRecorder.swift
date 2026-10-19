import AVFoundation
import AppKit

struct CameraChoice: Identifiable, Hashable {
    let id: String
    let name: String

    static func all() -> [CameraChoice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
    }
}

enum WebcamError: LocalizedError {
    case noCamera
    var errorDescription: String? { "The selected camera isn't available." }
}

/// Records the camera to its own H.264 file. Frame times are converted to the host clock (the
/// clock ScreenCaptureKit uses), so the file's offset against the screen video is exact.
final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let url: URL
    private let queue = DispatchQueue(label: "screenframe.webcam", qos: .userInteractive)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var startHostTime: Double?
    private(set) var size = CGSize.zero
    private var recording = true
    /// Set once the camera delivered a picture (read by the preview bubble).
    private(set) var gotFrame = false
    private var errorObserver: NSObjectProtocol?
    private let device: AVCaptureDevice
    /// Frame size once the preferred format is active; frames of another size are skipped so the
    /// file never changes size mid-stream.
    private var expectedSize: CMVideoDimensions?
    let cameraName: String

    init(deviceID: String?, url: URL) throws {
        self.url = url
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
        guard let device, let deviceInput = try? AVCaptureDeviceInput(device: device) else { throw WebcamError.noCamera }
        cameraName = device.localizedName
        self.device = device
        super.init()
        guard session.canAddInput(deviceInput) else { throw WebcamError.noCamera }
        session.beginConfiguration()
        // No fixed preset: some cameras (a DJI Osmo) deliver no frames at all when forced to
        // 1280×720. The landscape format is picked after start (see `usePreferredFormat`).
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        session.addInput(deviceInput)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        // A camera hiccup (USB reconnect, another app grabbing it) stops the session; start it again.
        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                               object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                guard self.recording else { return }
                self.session.startRunning()
                self.expectedSize = Self.usePreferredFormat(self.device)
            }
        }
    }

    /// Switches the camera to its best landscape format up to 1080p. Some cameras start in a
    /// portrait mode (Osmo: a 1080×1920 frame with the picture letterboxed in the middle).
    /// Must run after `startRunning`, which resets the format to the session preset.
    @discardableResult
    static func usePreferredFormat(_ device: AVCaptureDevice) -> CMVideoDimensions {
        let current = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if current.width >= current.height, current.width <= 1920 { return current }
        let candidates = device.formats.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width >= d.height && d.width <= 1920
                && $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 24 }
        }
        guard let best = candidates.max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription), b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }), (try? device.lockForConfiguration()) != nil else { return current }
        device.activeFormat = best
        device.unlockForConfiguration()
        return CMVideoFormatDescriptionGetDimensions(best.formatDescription)
    }

    deinit {
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
    }

    func start() {
        queue.async {
            self.session.startRunning()
            self.expectedSize = Self.usePreferredFormat(self.device)
        }
    }

    /// Stops and returns the track info relative to the screen video's first frame.
    func stop(screenStart: Double) async -> WebcamTrackInfo? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                recording = false
                session.stopRunning()
                guard let writer, let input, let start = startHostTime, writer.status == .writing else {
                    writer?.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed
                        ? WebcamTrackInfo(file: self.url.lastPathComponent, offset: start - screenStart,
                                          width: self.size.width, height: self.size.height)
                        : nil)
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, let format = sampleBuffer.formatDescription, let expectedSize else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == expectedSize.width, dimensions.height == expectedSize.height else { return }
        if !gotFrame { gotFrame = true }
        if writer == nil {
            size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(6_000_000, Int(dimensions.width) * Int(dimensions.height) * 7)],
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return }
            writer.add(input)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            let hostTime = session.synchronizationClock.map {
                CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: $0, to: CMClockGetHostTimeClock())
            } ?? sampleBuffer.presentationTimeStamp
            startHostTime = hostTime.seconds
            self.writer = writer
            self.input = input
        }
        if let input, input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }
}

/// A round, draggable live preview of the camera while recording. Our windows are excluded from
/// the screen capture, so it never appears in the video.
@MainActor
enum WebcamPreview {
    private static var panel: NSPanel?
    private static var statusTimer: Timer?

    /// `content` is the recorded area in Cocoa screen coordinates; the bubble starts in its
    /// bottom-right corner and can be dragged anywhere. Until the camera delivers a picture the
    /// bubble says so, and after a few seconds without one it warns instead of staying black.
    static func show(webcam: WebcamRecorder, inside content: NSRect) {
        hide()
        let size: CGFloat = min(180, max(110, content.height * 0.22))
        let panel = NSPanel(contentRect: NSRect(x: content.maxX - size - 24, y: content.minY + 24, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        view.layer?.cornerRadius = size / 2
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor

        let status = NSTextField(wrappingLabelWithString: "\(webcam.cameraName)\nWaiting for image…")
        status.alignment = .center
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .white
        status.frame = NSRect(x: size * 0.15, y: size * 0.3, width: size * 0.7, height: size * 0.4)
        view.addSubview(status)

        let preview = AVCaptureVideoPreviewLayer(session: webcam.session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        preview.isHidden = true
        view.layer?.addSublayer(preview)
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel

        let shown = Date()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                if webcam.gotFrame {
                    preview.isHidden = false
                    status.isHidden = true
                    timer.invalidate()
                } else if Date().timeIntervalSince(shown) > 4 {
                    status.stringValue = "No image from\n\(webcam.cameraName)\n\nPick another camera\nin ScreenFrame"
                    status.textColor = NSColor.systemOrange
                    status.frame = NSRect(x: size * 0.1, y: size * 0.22, width: size * 0.8, height: size * 0.56)
                }
            }
        }
    }

    static func hide() {
        statusTimer?.invalidate()
        statusTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Current bubble frame in global top-left-origin points (the capture coordinate system).
    static var frameTopLeft: CGRect? {
        guard let frame = panel?.frame else { return nil }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
