import AppKit

struct AreaChoice: Equatable {
    let displayID: CGDirectDisplayID
    /// Display-local points, top-left origin.
    let rect: CGRect
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}

/// Screenshot-style area picker: dims every display, drag a rectangle on any of them, Esc cancels.
@MainActor
enum AreaSelector {
    private static var windows: [NSWindow] = []
    private static var continuation: CheckedContinuation<AreaChoice?, Never>?

    static func select() async -> AreaChoice? {
        finish(nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                guard let id = screen.displayID else { continue }
                let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.setFrame(screen.frame, display: false)
                window.level = .screenSaver
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.onFinish = { rect in
                    finish(rect.map { r in
                        AreaChoice(displayID: id, rect: CGRect(x: r.minX.rounded(), y: (screen.frame.height - r.maxY).rounded(),
                                                               width: r.width.rounded(), height: r.height.rounded()))
                    })
                }
                window.contentView = view
                windows.append(window)
                window.makeKeyAndOrderFront(nil)
                if NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) {
                    window.makeKey()
                    window.makeFirstResponder(view)
                }
            }
            NSApp.activate()
            NSCursor.crosshair.push()
        }
    }

    private static func finish(_ choice: AreaChoice?) {
        guard !windows.isEmpty || continuation != nil else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.pop()
        continuation?.resume(returning: choice)
        continuation = nil
    }

    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        var onFinish: ((CGRect?) -> Void)?
        private var start: NSPoint?
        private var current: NSPoint?

        private var selection: NSRect? {
            guard let start, let current else { return nil }
            return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.4).setFill()
            bounds.fill()
            if let rect = selection {
                NSColor.clear.setFill()
                rect.fill(using: .copy)
                let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
                border.lineWidth = 2
                border.setLineDash([6, 4], count: 2, phase: 0)
                NSColor.white.setStroke()
                border.stroke()
                label("\(Int(rect.width)) × \(Int(rect.height))", at: NSPoint(x: rect.midX, y: rect.minY - 26))
            } else {
                label("Drag to select the area to record  ·  Esc to cancel", at: NSPoint(x: bounds.midX, y: bounds.midY))
            }
        }

        private func label(_ text: String, at point: NSPoint) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                             .foregroundColor: NSColor.white]
            let size = (text as NSString).size(withAttributes: attributes)
            let box = NSRect(x: point.x - size.width / 2 - 10, y: max(8, point.y - 4), width: size.width + 20, height: size.height + 8)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            (text as NSString).draw(at: NSPoint(x: box.minX + 10, y: box.minY + 4), withAttributes: attributes)
        }

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            current = start
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            current = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            current = convert(event.locationInWindow, from: nil)
            if let rect = selection, rect.width >= 40, rect.height >= 40 {
                onFinish?(rect)
            } else {
                start = nil
                current = nil
                needsDisplay = true
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
        }

        override func cancelOperation(_ sender: Any?) { onFinish?(nil) }
    }
}

/// A dashed frame around the recorded area while recording. Our windows are excluded from the
/// capture, so it never appears in the video.
@MainActor
enum RecordingFrameHUD {
    private static var window: NSWindow?

    static func show(_ area: AreaChoice) {
        hide()
        guard let screen = NSScreen.screen(for: area.displayID) else { return }
        let rect = NSRect(x: screen.frame.minX + area.rect.minX, y: screen.frame.maxY - area.rect.maxY,
                          width: area.rect.width, height: area.rect.height).insetBy(dx: -4, dy: -4)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(rect, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = FrameView(frame: NSRect(origin: .zero, size: rect.size))
        window.orderFrontRegardless()
        self.window = window
    }

    static func hide() {
        window?.orderOut(nil)
        window = nil
    }

    private final class FrameView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            path.lineWidth = 2
            path.setLineDash([8, 5], count: 2, phase: 0)
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}
