import AppKit
import SwiftUI

/// Debug: renders the editor's inspector to a PNG, for checking layouts without a screen capture.
///
///     ScreenFrame --snapshot <project> [tab] [out.png] [height] [light]
enum InspectorSnapshot {
    static func run(_ args: [String]) -> Never {
        MainActor.assumeIsolated {
            guard let path = args.first, let project = try? ProjectStore.load(URL(fileURLWithPath: path)) else {
                FileHandle.standardError.write(Data("usage: --snapshot <project> [tab] [out.png] [height] [light]\n".utf8))
                exit(1)
            }
            UserDefaults.standard.set(args.count > 1 ? args[1] : "social", forKey: "inspectorTab")
            let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/inspector.png")
            let height = args.count > 3 ? Double(args[3]) ?? 900 : 900
            let model = EditorModel(project: project)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let view = NSHostingView(rootView: InspectorView(model: model).frame(width: 330, height: height))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: height), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: args.count > 4 && args[4] == "light" ? .aqua : .darkAqua)
            window.contentView = view
            // Give thumbnails and other async content a moment, then draw.
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                MainActor.assumeIsolated {
                    view.layoutSubtreeIfNeeded()
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out)
                        print("→ \(out.path)")
                    }
                    _ = window
                    exit(0)
                }
            }
            app.run()
        }
        exit(0)
    }
}
