import AVFoundation
import SwiftUI

/// Live, mirrored preview of a camera. The capture session only runs while the view's window is
/// actually visible and `active` is true, so the camera light goes off when the home window is
/// hidden, covered or a recording takes over the camera.
struct CameraPreview: NSViewRepresentable {
    let deviceID: String
    let active: Bool

    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView() }

    func updateNSView(_ view: CameraPreviewView, context: Context) {
        view.configure(deviceID: deviceID, active: active)
    }

    static func dismantleNSView(_ view: CameraPreviewView, coordinator: ()) {
        view.configure(deviceID: "", active: false)
    }
}

final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let queue = DispatchQueue(label: "screenframe.camera-preview")
    private var deviceID: String?
    private var active = false
    private var running = false
    private var occlusionObserver: NSObjectProtocol?

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        // Mirror like the default bubble in the editor.
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                       object: window, queue: .main) { [weak self] _ in
                self?.update()
            }
        }
        update()
    }

    func configure(deviceID: String, active: Bool) {
        self.active = active
        if deviceID != self.deviceID {
            self.deviceID = deviceID
            let session = self.session
            queue.async {
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                // The camera's own format: fixed smaller presets give some cameras (DJI Osmo) no picture at all.
                if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                let device = deviceID.isEmpty ? AVCaptureDevice.default(for: .video) : AVCaptureDevice(uniqueID: deviceID)
                if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
            }
        }
        update()
    }

    private func update() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let shouldRun = active && visible && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        guard shouldRun != running else { return }
        running = shouldRun
        let session = self.session
        queue.async {
            guard shouldRun else { return session.stopRunning() }
            session.startRunning()
            if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device { WebcamRecorder.usePreferredFormat(device) }
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        let session = self.session
        queue.async { session.stopRunning() }
    }
}
