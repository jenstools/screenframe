import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var state: AppState
    var openProject: (URL) -> Void
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if state.permissionMissing { permissionCard }
            recordCard
            projectsList
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 600)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(Label("Drop videos to start a project", systemImage: "film").font(.title3.weight(.semibold)))
                    .padding(8)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let fileURL = URL(dataRepresentation: url, relativeTo: nil) { urls.append(fileURL) }
                }
                await state.createProject(fromVideos: urls)
            }
            return true
        }
        .task { await state.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await state.refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0x7F5AF0), Color(hex: 0x2CB1BC)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 2) {
                Text("ScreenFrame").font(.title2.bold())
                Text("Record raw. Polish later.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    state.openVideos()
                } label: {
                    Label(state.creatingProject ? "Opening…" : "Open Video…", systemImage: "film")
                }
                .disabled(state.creatingProject)
                .help("Start a project from existing video files (or drop them on this window)")
                Button {
                    state.importScreenStudio()
                } label: {
                    Label("Import Screen Studio…", systemImage: "square.and.arrow.down")
                }
            }
            .controlSize(.small)
        }
        .padding(.top, 8)
    }

    private var permissionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen Recording permission needed").font(.headline)
                Text("Allow ScreenFrame in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings") { state.requestPermission() }
                    Button("Relaunch") { state.relaunch() }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Record", selection: $state.captureMode) {
                ForEach(AppState.CaptureMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch state.captureMode {
            case .display:
                Picker("Display", selection: $state.selectedDisplay) {
                    ForEach(state.displays) { display in
                        Text("\(display.name)  ·  \(display.detail)").tag(Optional(display.id))
                    }
                }
                .disabled(state.displays.isEmpty)
            case .window:
                HStack {
                    Picker("Window", selection: $state.selectedWindow) {
                        if state.windows.isEmpty { Text("No windows found").tag(CGWindowID?.none) }
                        ForEach(state.windows) { window in
                            Text("\(window.app) — \(window.title)  ·  \(window.detail)").lineLimit(1).tag(Optional(window.id))
                        }
                    }
                    Button { Task { await state.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh the window list")
                }
            case .area:
                HStack {
                    if let area = state.area {
                        Image(systemName: "rectangle.dashed").foregroundStyle(.secondary)
                        Text("\(Int(area.rect.width)) × \(Int(area.rect.height)) on \(state.displays.first { $0.id == area.displayID }?.name ?? "display")")
                        Spacer()
                        Button("Change…") { Task { await state.selectArea() } }
                    } else {
                        Text("Drag out the part of the screen to record.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Select Area…") { Task { await state.selectArea() } }
                    }
                }
            }

            HStack(spacing: 18) {
                Toggle(isOn: $state.systemAudio) { Label("System audio", systemImage: "speaker.wave.2") }
                Toggle(isOn: $state.microphone) { Label("Microphone", systemImage: "mic") }
                Toggle(isOn: $state.camera) { Label("Camera", systemImage: "video") }
            }
            .toggleStyle(.checkbox)
            if state.microphone {
                MicMeterView(active: state.phase == .idle)
            }
            if state.camera {
                HStack(alignment: .center, spacing: 14) {
                    cameraPreview
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Camera", selection: $state.cameraID) {
                            if state.cameras.isEmpty { Text("No camera found").tag("") }
                            ForEach(state.cameras) { Text($0.name).tag($0.id) }
                        }
                        Text("Shape, size and corner are set per project in the editor (Camera section).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 6) {
                Toggle(isOn: $state.captureTyping) { Label("Capture typing for speed-up", systemImage: "keyboard") }
                    .toggleStyle(.checkbox)
                    .help("Records only when keys are pressed, never which keys, so typing stretches can be sped up in the editor.")
                if state.captureTyping, !state.accessibilityGranted {
                    Button("Allow in Accessibility…") { state.requestAccessibility() }
                        .controlSize(.small)
                }
            }

            Button {
                state.toggleRecording()
            } label: {
                HStack {
                    Image(systemName: "record.circle.fill")
                    Text(recordLabel).fontWeight(.semibold)
                    Spacer()
                    Text("⌘⇧2 · retake ⌘⇧1").font(.callout.monospaced()).opacity(0.75)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.white)
                .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(state.permissionMissing || state.phase == .finishing)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var cameraPreview: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.6))
            switch state.cameraAccess {
            case .authorized:
                if state.cameras.isEmpty {
                    Image(systemName: "video.slash").foregroundStyle(.secondary)
                } else {
                    CameraPreview(deviceID: state.cameraID, active: state.cameraPreviewActive && state.phase == .idle)
                        .clipShape(Circle())
                }
            case .denied, .restricted:
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "video.slash")
                        Text("Allow camera").font(.caption2)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            default:
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 92, height: 92)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private var recordLabel: String {
        switch state.phase {
        case .idle: return "Start Recording"
        case .countdown(let n): return "Starting in \(n)…"
        case .recording: return "Stop Recording"
        case .finishing: return "Saving…"
        }
    }

    private var projectsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent").font(.headline)
            if state.projects.isEmpty {
                Text("Your recordings will appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.projects) { project in
                            ProjectRow(summary: project)
                                .contentShape(Rectangle())
                                .onTapGesture { openProject(project.url) }
                                .contextMenu {
                                    Button("Open") { openProject(project.url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { state.delete(project) }
                                }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct ProjectRow: View {
    let summary: ProjectStore.Summary
    @State private var thumbnail: CGImage?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name).lineLimit(1)
                Text("\(formatDuration(summary.duration))  ·  \(summary.created.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .task(id: summary.url) {
            guard thumbnail == nil, let project = try? ProjectStore.load(summary.url) else { return }
            thumbnail = try? await Exporter.still(project: project, at: min(1, project.totalDuration / 2), maxLongSide: 320)
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
