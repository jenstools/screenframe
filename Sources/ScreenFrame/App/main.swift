import AppKit

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
