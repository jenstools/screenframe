import AppKit
import CoreMedia
import QuartzCore

/// Polls the mouse at 120 Hz on the main thread. Polling (instead of an event tap) needs no
/// Accessibility or Input Monitoring permission. Times are host-clock seconds, the same clock
/// ScreenCaptureKit stamps frames with, so they line up with the video exactly.
final class InputSampler {
    struct RawMouse { var host: Double; var x: Double; var y: Double; var cursor: String? }
    struct RawClick { var host: Double; var x: Double; var y: Double; var down: Bool; var button: Int }

    /// Top-left of the captured content in global top-left-origin points. Re-evaluated per sample
    /// so a recorded window can move.
    private let origin: () -> CGPoint
    private let pixelScale: Double
    private let cursorsDir: URL

    private(set) var mouse: [RawMouse] = []
    private(set) var clicks: [RawClick] = []
    private(set) var cursors: [CursorImageInfo] = []
    /// Host times of key presses. Only the time is kept, never which key.
    private(set) var keystrokes: [Double] = []
    private var keyMonitor: Any?
    /// Camera bubble centre over time, normalized to the content (top-left origin).
    private(set) var webcamPath: [(host: Double, x: Double, y: Double)] = []
    /// Host time the mouse entered the stop control and stayed there, for trimming the tail.
    private(set) var enteredControlsAt: Double?

    /// Size of the captured content in points (for normalizing the camera bubble position).
    var contentSize = CGSize(width: 1, height: 1)
    /// Global top-left-origin frame of the camera preview bubble, if shown.
    var webcamFrame: (() -> CGRect?)?
    /// Our own on-screen controls (stop pill, camera bubble). Clicks there aren't recorded.
    var excludedFrames: (() -> [CGRect])?
    /// The stop control's frame, for detecting the final move to the Stop button.
    var controlsFrame: (() -> CGRect?)?

    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var lastButtons = 0
    private var cursorID: String?
    private var cursorIDsByHash: [Int: String] = [:]

    init(origin: @escaping () -> CGPoint, pixelScale: Double, cursorsDir: URL) {
        self.origin = origin
        self.pixelScale = pixelScale
        self.cursorsDir = cursorsDir
    }

    /// Logs key-press times (needs Accessibility permission; without it nothing arrives).
    func captureTyping() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.isARepeat else { return }
            self?.keystrokes.append(CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func sample() {
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        // NSEvent.mouseLocation is bottom-left based on the primary display; capture origins are
        // top-left based. Convert to the captured content's pixel grid.
        let location = NSEvent.mouseLocation
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let topLeft = origin()
        let x = (location.x - topLeft.x) * pixelScale
        let y = (primaryHeight - location.y - topLeft.y) * pixelScale

        let globalPoint = CGPoint(x: location.x, y: primaryHeight - location.y)
        if tick % 6 == 0 {
            updateCursor()
            sampleWebcam(host: host, topLeft: topLeft)
            if let frame = controlsFrame?(), frame.insetBy(dx: -12, dy: -12).contains(globalPoint) {
                if enteredControlsAt == nil { enteredControlsAt = host }
            } else {
                enteredControlsAt = nil
            }
        }
        tick += 1

        let moved = mouse.last.map { abs($0.x - x) > 0.25 || abs($0.y - y) > 0.25 || $0.cursor != cursorID || host - $0.host > 0.25 } ?? true
        if moved { mouse.append(RawMouse(host: host, x: x, y: y, cursor: cursorID)) }

        let buttons = NSEvent.pressedMouseButtons
        let onOwnControls = excludedFrames?().contains { $0.contains(globalPoint) } ?? false
        for button in 0..<3 {
            let was = (lastButtons >> button) & 1, now = (buttons >> button) & 1
            if was != now, !onOwnControls { clicks.append(RawClick(host: host, x: x, y: y, down: now == 1, button: button)) }
        }
        lastButtons = buttons
    }

    private func sampleWebcam(host: Double, topLeft: CGPoint) {
        guard let frame = webcamFrame?(), contentSize.width > 0, contentSize.height > 0 else { return }
        let x = (frame.midX - topLeft.x) / contentSize.width, y = (frame.midY - topLeft.y) / contentSize.height
        if let last = webcamPath.last, abs(last.x - x) < 0.001, abs(last.y - y) < 0.001 { return }
        webcamPath.append((host, x, y))
    }

    private func updateCursor() {
        guard let cursor = NSCursor.currentSystem, let tiff = cursor.image.tiffRepresentation else {
            cursorID = nil
            return
        }
        var hasher = Hasher()
        hasher.combine(tiff)
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        let key = hasher.finalize()
        if let id = cursorIDsByHash[key] {
            cursorID = id
            return
        }
        let id = "c\(cursorIDsByHash.count)"
        if let png = Self.png(of: cursor.image) {
            try? png.write(to: cursorsDir.appendingPathComponent("\(id).png"))
            cursors.append(CursorImageInfo(id: id, hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y,
                                           width: cursor.image.size.width, height: cursor.image.size.height))
        }
        cursorIDsByHash[key] = id
        cursorID = id
    }

    /// Renders the cursor at its sharpest representation (at least 4x) so it stays crisp when the
    /// editor scales it up or zooms in.
    private static func png(of image: NSImage) -> Data? {
        let best = image.representations.map(\.pixelsWide).max() ?? 0
        let scale = max(4.0, Double(best) / max(1, image.size.width))
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Follows a window's position (CGWindowList, at most 10 times a second).
final class WindowTracker {
    private let windowID: CGWindowID
    private var origin: CGPoint
    private var updated = 0.0

    init(windowID: CGWindowID, origin: CGPoint) {
        self.windowID = windowID
        self.origin = origin
    }

    func current() -> CGPoint {
        let now = CACurrentMediaTime()
        guard now - updated > 0.1 else { return origin }
        updated = now
        if let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
           let bounds = info[kCGWindowBounds as String] as? [String: Any],
           let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
            origin = rect.origin
        }
        return origin
    }
}
