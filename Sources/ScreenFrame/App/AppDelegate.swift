import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState.shared
    private var homeWindow: NSWindow?
    private var editors: [URL: (window: NSWindow, model: EditorModel, keys: Any?)] = [:]
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?
    private var hotKey: HotKey?
    private var retakeHotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []

    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM (e.g. from the installer script): save open projects, then exit even if a
        // dialog is open.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.editors.values.forEach { $0.model.teardown() }
                exit(0)
            }
        }
        source.resume()
        termination = source
        NSApp.mainMenu = makeMainMenu()
        makeStatusItem()
        hotKey = HotKey(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey, id: 1) { [weak self] in
            self?.state.toggleRecording()
        }
        retakeHotKey = HotKey(keyCode: kVK_ANSI_1, modifiers: cmdKey | shiftKey, id: 2) { [weak self] in
            self?.state.markRetake()
        }

        state.onRecordingWillStart = { [weak self] in
            self?.homeWindow?.orderOut(nil)
        }
        state.homeWindowVisibility = { [weak self] visible in
            if visible { self?.showHome() } else { self?.homeWindow?.orderOut(nil) }
        }
        state.onRecordingFinished = { [weak self] url in
            self?.openEditor(url)
        }
        state.onError = { message in
            let alert = NSAlert()
            alert.messageText = "ScreenFrame"
            alert.informativeText = message
            alert.runModal()
        }
        state.$phase.sink { [weak self] phase in self?.updateStatusItem(phase) }.store(in: &cancellables)

        showHome()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showHome() }
        return true
    }

    /// `open -a ScreenFrame <project folder>` and dropping a project on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.appendingPathComponent("recording.json").path) {
            openEditor(url)
        }
        // Video files opened with ScreenFrame start a new project.
        let videos = urls.filter { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("recording.json").path) }
        if !videos.isEmpty { Task { await state.createProject(fromVideos: videos) } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        editors.values.forEach { $0.model.teardown() }
    }

    // MARK: Windows

    @objc func showHome() {
        if homeWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HomeView(state: state) { [weak self] url in self?.openEditor(url) })
            window.setFrameAutosaveName("ScreenFrameHome")
            if !window.setFrameUsingName("ScreenFrameHome") { window.center() }
            homeWindow = window
        }
        homeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openEditor(_ url: URL) {
        if let existing = editors[url] {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let project: Project
        do {
            project = try ProjectStore.load(url)
        } catch {
            state.onError?("Could not open the project: \(error.localizedDescription)")
            return
        }
        let model = EditorModel(project: project)
        model.openProject = { [weak self] url in self?.openEditor(url) }
        model.openSubtitleEditor = { [weak self, weak model] in
            guard let self, let model else { return }
            self.openSubtitles(for: model, url: url)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = project.doc.name
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: EditorView(model: model))
        window.setContentSize(NSSize(width: 1320, height: 820))
        window.center()
        window.delegate = self
        // Single-key editor shortcuts (Space, Z, T, B, ⌫, arrows) without stealing keys from text fields.
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak model] event in
            guard let window, let model, event.window === window else { return event }
            if window.firstResponder is NSText {
                // Esc leaves a text field, so Space plays again.
                if event.keyCode == 53 { window.makeFirstResponder(nil); return nil }
                return event
            }
            return MainActor.assumeIsolated { model.handleKey(event) } ? nil : event
        }
        editors[url] = (window, model, keys)
        window.makeKeyAndOrderFront(nil)
        // SwiftUI focuses the first text field (the AI prompt) on open, which would swallow Space.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in window?.makeFirstResponder(nil) }
        NSApp.activate()
    }

    private var subtitleWindows: [URL: NSWindow] = [:]

    /// The subtitle editor, as its own window so the video stays visible next to it.
    func openSubtitles(for model: EditorModel, url: URL) {
        if let window = subtitleWindows[url] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Subtitles — \(model.name)"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubtitleEditorView(model: model))
        window.setContentSize(NSSize(width: 960, height: 720))
        if let editor = editors[url]?.window {
            // Beside the editor when there's room, otherwise centred.
            let frame = editor.frame
            window.setFrameOrigin(NSPoint(x: min(frame.maxX - 200, (editor.screen?.visibleFrame.maxX ?? frame.maxX) - 960),
                                          y: frame.minY + 40))
        } else {
            window.center()
        }
        subtitleWindows[url] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = editors.first(where: { $0.value.window === window }) else { return }
        entry.value.model.teardown()
        if let keys = entry.value.keys { NSEvent.removeMonitor(keys) }
        subtitleWindows[entry.key]?.close()
        subtitleWindows[entry.key] = nil
        editors[entry.key] = nil
        Task { await state.refresh() }
    }

    // MARK: Menu bar

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.inset.filled.and.cursorarrow", accessibilityDescription: "ScreenFrame")
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateStatusItem(.idle)
    }

    private func updateStatusItem(_ phase: AppState.Phase) {
        guard let item = statusItem, let button = item.button else { return }
        statusTimer?.invalidate()
        statusTimer = nil
        switch phase {
        case .recording(let since):
            item.menu = nil
            button.target = self
            button.action = #selector(stopFromStatusItem)
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            let tick = { button.title = " " + formatDuration(Date().timeIntervalSince(since)) }
            tick()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        case .countdown(let n):
            item.menu = nil
            button.title = " \(n)"
        case .finishing:
            item.menu = nil
            button.title = " Saving…"
        case .idle:
            button.title = ""
            button.action = nil
            button.image = NSImage(systemSymbolName: "rectangle.inset.filled.and.cursorarrow", accessibilityDescription: "ScreenFrame")
            let menu = NSMenu()
            menu.addItem(withTitle: "Start Recording", action: #selector(startFromMenu), keyEquivalent: "2")
                .keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(withTitle: "Open ScreenFrame", action: #selector(showHome), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit ScreenFrame", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
            item.menu = menu
        }
    }

    /// Text fields keep their own undo; everywhere else in an editor window undo edits the project.
    @objc private func performUndo(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSText { text.undoManager?.undo(); return }
        keyEditor?.undo()
    }

    @objc private func performRedo(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSText { text.undoManager?.redo(); return }
        keyEditor?.redo()
    }

    private var keyEditor: EditorModel? {
        editors.values.first { $0.window === NSApp.keyWindow }?.model
    }

    @objc private func stopFromStatusItem() { state.toggleRecording() }
    @objc private func startFromMenu() { state.toggleRecording() }
    @objc private func importScreenStudio() { state.importScreenStudio() }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ScreenFrame", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ScreenFrame", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ScreenFrame", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Recording…", action: #selector(showHome), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "Import Screen Studio Project…", action: #selector(importScreenStudio), keyEquivalent: "i").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(performUndo(_:)), keyEquivalent: "z").target = self
        editMenu.addItem(withTitle: "Redo", action: #selector(performRedo(_:)), keyEquivalent: "Z").target = self
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
