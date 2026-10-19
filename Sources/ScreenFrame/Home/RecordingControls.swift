import AppKit
import SwiftUI

/// Floating stop control while recording: red dot, elapsed time and a Stop button. Our windows
/// are excluded from the capture, and clicks on it aren't recorded.
@MainActor
enum RecordingControls {
    private static var panel: NSPanel?

    static func show(state: AppState, on screen: NSScreen?) {
        hide()
        let size = NSSize(width: 214, height: 44)
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let panel = NSPanel(contentRect: NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 14,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: ControlsView(state: state))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Global top-left-origin frame (the capture coordinate system).
    static var frameTopLeft: CGRect? {
        guard let frame = panel?.frame else { return nil }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

private struct ControlsView: View {
    @ObservedObject var state: AppState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            SwiftUI.TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(elapsed).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(.white)
            }
            Spacer(minLength: 0)
            Button {
                state.markRetake()
            } label: {
                Image(systemName: state.retakeCount > 0 ? "arrow.counterclockwise.circle.fill" : "arrow.counterclockwise.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Take again (⌘⇧1): cuts the sentence you just said")
            Button {
                state.toggleRecording()
            } label: {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10)
                    Text("Stop").font(.callout.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Stop recording (⌘⇧2)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(width: 214, height: 44)
        .background(Color.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
    }

    private var elapsed: String {
        guard case .recording(let since) = state.phase else { return "0:00" }
        return formatDuration(Date().timeIntervalSince(since))
    }
}
