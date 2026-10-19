import AppKit
import SwiftUI

/// 3-2-1 overlay centred on the display being recorded. Our own windows are excluded from the
/// capture, so it never shows up in the video.
@MainActor
enum CountdownHUD {
    private static var panel: NSPanel?

    static func show(_ number: Int, on displayID: CGDirectDisplayID) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: CountdownView(number: number))
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
        if let frame = screen?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 90, y: frame.midY - 90))
        }
        panel.orderFrontRegardless()
    }

    static func hide() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private struct CountdownView: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 96, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 180, height: 180)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 40, style: .continuous))
    }
}
