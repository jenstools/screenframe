import AppKit

if CommandLine.arguments.dropFirst().first == "--snapshot" {
    // Needs a real main-thread run loop for SwiftUI, unlike the other CLI commands.
    InspectorSnapshot.run(Array(CommandLine.arguments.dropFirst(2)))
}

if CLI.handles(CommandLine.arguments) {
    CLI.run(CommandLine.arguments)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
