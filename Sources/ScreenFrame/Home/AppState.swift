import AVFoundation
import AppKit
import UniformTypeIdentifiers
import ApplicationServices
import ScreenCaptureKit

/// Recording lifecycle and the home window's data.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    struct DisplayChoice: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let detail: String
    }

    struct WindowChoice: Identifiable, Hashable {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let title: String
        let detail: String
        let displayID: CGDirectDisplayID?
    }

    enum CaptureMode: String, CaseIterable, Identifiable {
        case display, window, area
        var id: String { rawValue }
        var label: String {
            switch self {
            case .display: return "Display"
            case .window: return "Window"
            case .area: return "Area"
            }
        }
        var symbol: String {
            switch self {
            case .display: return "display"
            case .window: return "macwindow"
            case .area: return "rectangle.dashed"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording(since: Date)
        case finishing
    }

    @Published var displays: [DisplayChoice] = []
    @Published var selectedDisplay: CGDirectDisplayID?
    @Published var captureMode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "") ?? .display {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode") }
    }
    @Published private(set) var windows: [WindowChoice] = []
    @Published var selectedWindow: CGWindowID?
    @Published var area: AreaChoice?
    @Published var camera = UserDefaults.standard.bool(forKey: "camera") {
        didSet {
            UserDefaults.standard.set(camera, forKey: "camera")
            if camera { Task { await requestCameraAccess() } }
        }
    }
    @Published private(set) var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    /// Off while a recording owns the camera.
    @Published private(set) var cameraPreviewActive = true
    @Published var cameraID = UserDefaults.standard.string(forKey: "cameraID") ?? "" {
        didSet { UserDefaults.standard.set(cameraID, forKey: "cameraID") }
    }
    @Published private(set) var cameras: [CameraChoice] = []
    /// Logs key-press times (never keys) so typing can be sped up later. Needs Accessibility.
    @Published var captureTyping = UserDefaults.standard.bool(forKey: "captureTyping") {
        didSet {
            UserDefaults.standard.set(captureTyping, forKey: "captureTyping")
            if captureTyping { requestAccessibility() }
        }
    }
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published var systemAudio = UserDefaults.standard.object(forKey: "systemAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(systemAudio, forKey: "systemAudio") }
    }
    @Published var microphone = UserDefaults.standard.bool(forKey: "microphone") {
        didSet { UserDefaults.standard.set(microphone, forKey: "microphone") }
    }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var retakeCount = 0
    @Published private(set) var permissionMissing = false
    @Published private(set) var projects: [ProjectStore.Summary] = []

    var onRecordingWillStart: (() -> Void)?
    var homeWindowVisibility: ((Bool) -> Void)?
    var onRecordingFinished: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private var recorder: Recorder?
    private var folder: URL?

    var isBusy: Bool { phase != .idle }

    func requestCameraAccess() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func refresh() async {
        projects = ProjectStore.list()
        cameras = CameraChoice.all()
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        accessibilityGranted = AXIsProcessTrusted()
        if !cameraID.isEmpty, !cameras.contains(where: { $0.id == cameraID }) { cameraID = cameras.first?.id ?? "" }
        if cameraID.isEmpty { cameraID = cameras.first?.id ?? "" }
        // Camera already switched on from an earlier session: ask now, so the preview can show.
        if camera, cameraAccess == .notDetermined { await requestCameraAccess() }
        guard CGPreflightScreenCaptureAccess() else {
            permissionMissing = true
            return
        }
        do {
            let content = try await SCShareableContent.current
            permissionMissing = false
            displays = content.displays.map { display in
                let screen = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                }
                let scale = screen?.backingScaleFactor ?? 1
                return DisplayChoice(id: display.displayID, name: screen?.localizedName ?? "Display \(display.displayID)",
                                     detail: "\(Int(CGFloat(display.width) * scale)) × \(Int(CGFloat(display.height) * scale))")
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let hidden: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
                                       "com.apple.notificationcenterui", "com.apple.Spotlight"]
            windows = content.windows
                .filter { window in
                    guard let app = window.owningApplication, window.isOnScreen, window.windowLayer == 0,
                          window.frame.width >= 160, window.frame.height >= 100,
                          app.processID != ownPID, !hidden.contains(app.bundleIdentifier) else { return false }
                    return !(window.title ?? "").isEmpty
                }
                .map { window in
                    let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                    let display = content.displays.first { $0.frame.contains(center) }
                    return WindowChoice(id: window.windowID, pid: window.owningApplication?.processID ?? 0, app: window.owningApplication?.applicationName ?? "App",
                                        title: window.title ?? "", detail: "\(Int(window.frame.width)) × \(Int(window.frame.height))",
                                        displayID: display?.displayID)
                }
                .sorted { ($0.app.lowercased(), $0.title) < ($1.app.lowercased(), $1.title) }
            if selectedWindow == nil || !windows.contains(where: { $0.id == selectedWindow }) {
                selectedWindow = windows.first?.id
            }
            if selectedDisplay == nil || !displays.contains(where: { $0.id == selectedDisplay }) {
                // Default to the display the mouse is on.
                let mouse = NSEvent.mouseLocation
                let current = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                let currentID = (current?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                selectedDisplay = displays.first { $0.id == currentID }?.id ?? displays.first?.id
            }
        } catch {
            permissionMissing = true
        }
    }

    func requestPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        // Screen Recording grants only apply to a fresh process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// "Take again": the sentence you just said is cut from the recording.
    func markRetake() {
        guard case .recording = phase, let recorder else { return }
        recorder.markRetake()
        retakeCount += 1
    }

    func toggleRecording() {
        switch phase {
        case .idle: Task { await start() }
        case .recording: Task { await stop() }
        case .countdown, .finishing: break
        }
    }

    /// The recorded content in Cocoa screen coordinates, for placing the camera bubble.
    private func contentFrame(for target: CaptureTarget) -> NSRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        func cocoa(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
        switch target {
        case .display(let id):
            return NSScreen.screen(for: id)?.visibleFrame ?? cocoa(CGDisplayBounds(id))
        case .area(let id, let rect):
            let bounds = CGDisplayBounds(id)
            return cocoa(rect.offsetBy(dx: bounds.minX, dy: bounds.minY))
        case .window(let id):
            if let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
               let dict = info[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) {
                return cocoa(rect)
            }
            return NSScreen.main?.visibleFrame ?? .zero
        }
    }

    func selectArea() async {
        homeWindowVisibility?(false)
        if let choice = await AreaSelector.select() { area = choice }
        homeWindowVisibility?(true)
    }

    func start() async {
        guard phase == .idle else { return }
        await refresh()
        guard !permissionMissing else {
            requestPermission()
            return
        }

        let target: CaptureTarget
        let countdownDisplay: CGDirectDisplayID
        switch captureMode {
        case .display:
            guard let id = selectedDisplay ?? displays.first?.id else { return }
            target = .display(id)
            countdownDisplay = id
        case .window:
            guard let window = windows.first(where: { $0.id == selectedWindow }) else {
                onError?("Choose a window to record.")
                return
            }
            target = .window(window.id)
            countdownDisplay = window.displayID ?? CGMainDisplayID()
            // Bring the window's app forward so it's visible while recording.
            NSRunningApplication(processIdentifier: window.pid)?.activate()
        case .area:
            if area == nil { await selectArea() }
            guard let area else { return }
            target = .area(area.displayID, area.rect)
            countdownDisplay = area.displayID
        }

        if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            onError?("Microphone access was denied. Enable it in System Settings › Privacy & Security › Microphone.")
            return
        }
        if camera, !(await AVCaptureDevice.requestAccess(for: .video)) {
            onError?("Camera access was denied. Enable it in System Settings › Privacy & Security › Camera.")
            return
        }

        cameraPreviewActive = false
        defer { if phase == .idle { cameraPreviewActive = true } }
        let folder: URL
        let recorder: Recorder
        do {
            folder = try ProjectStore.newProjectFolder()
            recorder = Recorder(folder: folder, options: RecordOptions(target: target, systemAudio: systemAudio, microphone: microphone,
                                                                       cameraID: camera ? cameraID : nil,
                                                                       captureTyping: captureTyping && AXIsProcessTrusted()))
            // The camera starts before the countdown so you can see yourself in the preview.
            try recorder.prepareCamera()
            if let webcam = recorder.webcam { WebcamPreview.show(webcam: webcam, inside: contentFrame(for: target)) }
            recorder.webcamFrame = { MainActor.assumeIsolated { WebcamPreview.frameTopLeft } }
            recorder.controlsFrame = { MainActor.assumeIsolated { RecordingControls.frameTopLeft } }
        } catch {
            onError?("Could not start the camera: \(error.localizedDescription)")
            return
        }

        onRecordingWillStart?()
        for n in stride(from: 3, through: 1, by: -1) {
            phase = .countdown(n)
            CountdownHUD.show(n, on: countdownDisplay)
            try? await Task.sleep(for: .milliseconds(800))
        }
        CountdownHUD.hide()

        do {
            recorder.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, case .recording = self.phase else { return }
                    self.onError?("Recording stopped: \(error.localizedDescription)")
                    await self.stop()
                }
            }
            try await recorder.start()
            self.recorder = recorder
            self.folder = folder
            retakeCount = 0
            phase = .recording(since: Date())
            if case .area(let id, let rect) = target { RecordingFrameHUD.show(AreaChoice(displayID: id, rect: rect)) }
            RecordingControls.show(state: self, on: NSScreen.screen(for: countdownDisplay))
        } catch {
            phase = .idle
            WebcamPreview.hide()
            _ = await recorder.webcam?.stop(screenStart: 0)
            onError?("Could not start recording: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard case .recording = phase, let recorder, let folder else { return }
        phase = .finishing
        RecordingFrameHUD.hide()
        RecordingControls.hide()
        WebcamPreview.hide()
        defer {
            self.recorder = nil
            self.folder = nil
            phase = .idle
            cameraPreviewActive = true
        }
        do {
            let info = try await recorder.stop()
            // "Take again" presses become cuts; stopping with the on-screen button drops the
            // bit where the mouse travels to it.
            let retakes = await Retakes.cuts(for: info, folder: folder)
            try ProjectStore.finalize(folder: folder, info: info, clipEnd: recorder.tailCut, cuts: retakes)
            projects = ProjectStore.list()
            onRecordingFinished?(folder)
            if let webcam = recorder.webcam, info.webcam == nil {
                onError?("\(webcam.cameraName) sent no image, so this recording has no camera. "
                         + "Pick another camera on the home screen; its preview there shows whether it works.")
            }
        } catch {
            onError?("Could not save the recording: \(error.localizedDescription)")
        }
    }

    func openVideos() {
        let panel = NSOpenPanel()
        panel.title = "Start from video files"
        panel.message = "Choose one or more videos. They become one project, one clip each."
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await createProject(fromVideos: urls) }
    }

    @Published private(set) var creatingProject = false

    func createProject(fromVideos urls: [URL]) async {
        let videos = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) ?? false }
        guard !videos.isEmpty, !creatingProject else { return }
        creatingProject = true
        defer { creatingProject = false }
        do {
            let project = try await ProjectStore.createProject(fromVideos: videos)
            projects = ProjectStore.list()
            onRecordingFinished?(project.url)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func importScreenStudio() {
        let panel = NSOpenPanel()
        panel.title = "Import a Screen Studio project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Screen Studio Projects")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let project = try await ScreenStudioImporter.importProject(at: url)
                projects = ProjectStore.list()
                onRecordingFinished?(project.url)
            } catch {
                onError?(error.localizedDescription)
            }
        }
    }

    func delete(_ summary: ProjectStore.Summary) {
        try? FileManager.default.trashItem(at: summary.url, resultingItemURL: nil)
        projects = ProjectStore.list()
    }
}
