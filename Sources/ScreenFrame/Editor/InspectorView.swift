import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    @AppStorage("inspectorTab") private var tab = Tab.ai

    enum Tab: String, CaseIterable, Identifiable {
        case ai, script, style, zoom, camera, audio, privacy, social, export
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ai: return "AI"
            case .script: return "Script"
            case .style: return "Style"
            case .zoom: return "Zoom"
            case .camera: return "Camera"
            case .audio: return "Audio"
            case .privacy: return "Privacy"
            case .social: return "Social"
            case .export: return "Export"
            }
        }
        var symbol: String {
            switch self {
            case .ai: return "sparkles"
            case .script: return "text.quote"
            case .style: return "paintpalette"
            case .zoom: return "plus.magnifyingglass"
            case .camera: return "video"
            case .audio: return "waveform"
            case .privacy: return "eye.slash"
            case .social: return "rectangle.portrait.on.rectangle.portrait"
            case .export: return "square.and.arrow.up"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.selection != nil {
                ScrollView {
                    selectionPanel
                        .overlay(alignment: .topTrailing) {
                            Button { model.selection = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Deselect (click empty timeline space)")
                            .padding(6)
                        }
                        .padding(12)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            tabBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case .ai: aiTab
                    case .script: TranscriptPanel(model: model)
                    case .style:
                        BrandKitSection(model: model)
                        background
                        frame
                        cursor
                    case .zoom:
                        zoom
                        motion
                    case .camera: cameraTab
                    case .audio:
                        if model.audioLanes.isEmpty {
                            EmptyState(symbol: "waveform.slash", text: "This project has no audio. Turn on System audio or Microphone when recording.")
                        } else {
                            audio
                        }
                        cleanup
                        captions
                    case .privacy: privacy
                    case .social: SocialTab(model: model)
                    case .export:
                        export
                        social
                        InspectorSection("Publish") {
                            HStack {
                                Button("Thumbnail…", action: model.openThumbnails)
                                Button("Content…", action: model.generateContentPackage)
                                Button("Guide", action: model.buildGuide).disabled(model.guideProgress != nil)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(.background.secondary)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                Button { tab = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 14, weight: .medium))
                            .frame(height: 16)
                        // Nine tabs share ~34 pt each: one line, shrinking a little for the long names.
                        Text(item.title).font(.system(size: 9.5, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .allowsTightening(true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 1)
                    .foregroundStyle(tab == item ? Color.accentColor : Color.secondary)
                    .background(tab == item ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
                .opacity(item == .camera && !model.hasWebcam ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    // MARK: Tabs

    @ViewBuilder private var aiTab: some View {
        AISection(model: model)
        InspectorSection("One-click") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ActionCard(symbol: "scissors", title: "Remove pauses", detail: "Cut dead air",
                           action: model.findSilences)
                ActionCard(symbol: "text.bubble", title: "Filler words", detail: "Find “ähm”, “uh”",
                           progress: model.isRunning("fillers") ? (model.progress(of: "words") ?? 0) : nil, action: model.findFillers)
                ActionCard(symbol: "captions.bubble", title: "Captions", detail: model.captions.isEmpty ? "From your voice" : "Edit \(model.captions.count) lines",
                           progress: model.captionProgress,
                           action: { model.captions.isEmpty ? model.generateCaptions() : model.openSubtitleEditor?() })
                ActionCard(symbol: "eye.slash", title: "Blur private info", detail: "Emails, names, keys",
                           progress: model.privacyProgress, action: model.scanPrivacy)
                ActionCard(symbol: "video.badge.waveform", title: "Auto camera", detail: "Full screen while talking",
                           enabled: model.hasWebcam, action: model.autoCameraLayout)
                ActionCard(symbol: "rectangle.portrait.on.rectangle.portrait", title: "Make Shorts",
                           detail: model.shorts.isEmpty ? "YouTube Shorts, 9:16" : "\(model.shorts.count) made · more",
                           progress: model.progress(of: "shorts"),
                           action: { tab = .social; model.makeShortsFromDefaults() })
            }
        }
        InspectorSection("Publish") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ActionCard(symbol: "doc.richtext", title: "Content package", detail: "Post, chapters, captions",
                           progress: model.contentBusy ? 0.5 : nil, action: model.generateContentPackage)
                ActionCard(symbol: "photo.on.rectangle", title: "Thumbnail", detail: "Best frame + headline",
                           progress: model.progress(of: "thumbnail"), action: model.openThumbnails)
                ActionCard(symbol: "list.number", title: "Step-by-step guide", detail: "PDF, HTML, Markdown",
                           progress: model.guideProgress, action: model.buildGuide)
                ActionCard(symbol: "text.quote", title: "Edit by script", detail: model.hasTranscript ? "\(model.transcriptWords.count) words" : "Delete words to cut",
                           progress: model.progress(of: "words"), action: { tab = .script; if !model.hasTranscript { model.transcribe() } })
            }
            if let folder = model.lastOutputFolder {
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: {
                    Label("Show last output in Finder", systemImage: "folder")
                }
                .controlSize(.small)
            }
        }
        if !model.cutSuggestions.isEmpty { CutReview(model: model) }
    }

    @ViewBuilder private var cameraTab: some View {
        if model.hasWebcam {
            camera
        } else {
            EmptyState(symbol: "video.slash", text: "This project has no camera recording. Tick “Camera” in the recording window to add one.")
        }
    }

    private var motion: some View {
        InspectorSection("Motion") {
            SliderRow("Motion blur", value: $model.settings.motionBlur, range: 0...1, format: "%.0f%%", multiplier: 100)
                .help("Blur on fast cursor moves and camera pans/zooms")
        }
    }

    // MARK: Sections

    private var background: some View {
        InspectorSection("Background") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 9), count: 6), alignment: .leading, spacing: 9) {
                ForEach(BackgroundPreset.all) { preset in
                    Button { model.settings.background = preset.id } label: {
                        Swatch(preset: preset, selected: model.settings.background == preset.id)
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }
            if model.settings.background == "wallpaper" {
                SliderRow("Blur", value: $model.settings.backgroundBlur, range: 0...60, format: "%.0f")
            }
        }
    }

    private var frame: some View {
        InspectorSection("Frame") {
            Picker("Aspect", selection: $model.settings.aspect) {
                ForEach(AspectChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            SliderRow("Padding", value: $model.settings.padding, range: 0...0.25, format: "%.0f%%", multiplier: 100)
            SliderRow("Corners", value: $model.settings.cornerRadius, range: 0...48, format: "%.0f")
            SliderRow("Shadow", value: $model.settings.shadow, range: 0...1, format: "%.0f%%", multiplier: 100)
            if model.settings.aspect != .source {
                Toggle("Fill frame & follow cursor", isOn: $model.settings.reframe)
                    .help("For 9:16 and 1:1: the recording fills the frame and the view follows the cursor")
            }
        }
    }

    private var cursor: some View {
        InspectorSection("Cursor") {
            Toggle("Show cursor", isOn: $model.settings.showCursor)
            SliderRow("Size", value: $model.settings.cursorScale, range: 0.6...3, format: "%.1f×")
                .disabled(!model.settings.showCursor)
            Toggle("Smooth movement", isOn: $model.settings.smoothCursor)
            Toggle("Click highlight", isOn: $model.settings.clickEffect)
        }
    }

    @ViewBuilder private var selectionPanel: some View {
        if let key = model.selectedCameraKey {
            CameraKeyPanel(model: model, key: key)
        } else if let blur = model.selectedBlur {
            BlurPanel(model: model, region: blur)
        } else if let zoom = model.selectedZoom {
            SelectedZoomPanel(model: model, zoom: zoom)
        } else if let index = model.selectedTextIndex {
            TextPanel(model: model, text: model.texts[index])
        } else if let placement = model.selectedPlacement {
            ClipPanel(model: model, placement: placement)
        }
    }

    private var zoom: some View {
        InspectorSection("Zoom") {
            Toggle("Zooms on", isOn: $model.settings.autoZoom)
                .help("Turn every zoom off (or back on) without deleting any. Shortcut: Z")
            Group {
                SliderRow("Auto level", value: $model.settings.zoomLevel, range: 1.2...3, format: "%.1f×")
                HStack {
                    Button("Regenerate", action: model.regenerateZooms)
                        .help("Rebuild the generated zooms from the recorded clicks (keeps zooms you edited)")
                    Button("Add at Playhead", action: model.addZoom)
                }
                .controlSize(.small)
            }
            .disabled(!model.settings.autoZoom)
            .opacity(model.settings.autoZoom ? 1 : 0.5)
        }
    }

    private var camera: some View {
        InspectorSection("Camera") {
            Toggle("Show camera", isOn: $model.settings.showCamera)
            Group {
                Picker("Shape", selection: $model.settings.cameraShape) {
                    ForEach(CameraShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                SliderRow("Size", value: $model.settings.cameraSize, range: 0.12...0.5, format: "%.0f%%", multiplier: 100)
                HStack {
                    Text("Position").frame(width: 70, alignment: .leading)
                    Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                        GridRow { cornerButton(.topLeft); cornerButton(.topRight) }
                        GridRow { cornerButton(.bottomLeft); cornerButton(.bottomRight) }
                    }
                    Spacer()
                    Toggle("Mirror", isOn: $model.settings.mirrorCamera)
                }
                if model.hasRecordedCameraPath {
                    Toggle("Follow where it was during recording", isOn: $model.settings.cameraFollowsRecording)
                }
                HStack {
                    Text("Background").frame(width: 70, alignment: .leading)
                    Picker("Background", selection: $model.settings.cameraBackground) {
                        ForEach(CameraBackground.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack {
                    Toggle("Keep my face centred", isOn: $model.settings.centerFace)
                        .onChange(of: model.settings.centerFace) { _, on in if on { model.analyzeFaces() } }
                    if let progress = model.faceProgress { ProgressView(value: progress).frame(width: 60) }
                }
                HStack {
                    Button("Add Keyframe") { model.addCameraKey() }
                        .help("Camera lane: from the playhead on, the camera moves to where you drag it")
                    Button("Auto Layout") { model.autoCameraLayout() }
                        .help("Full screen while you talk and nothing happens on screen")
                    if !model.cameraKeys.isEmpty {
                        Button(role: .destructive) { model.removeCameraKeys() } label: { Image(systemName: "trash") }
                            .help("Remove all camera keyframes")
                    }
                }
                .controlSize(.small)
                Text(model.cameraKeys.isEmpty
                     ? "Drag the camera on the preview to put it anywhere. Add keyframes to move it at different moments."
                     : "With keyframes, dragging the camera sets its position at the playhead (\(model.cameraKeys.count) keyframes).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!model.settings.showCamera)
            .opacity(model.settings.showCamera ? 1 : 0.5)
        }
    }

    private var cleanup: some View {
        InspectorSection("Clean up") {
            HStack {
                Button("Find Pauses", action: model.findSilences)
                Button("Find Filler Words", action: model.findFillers)
            }
            .controlSize(.small)
            Toggle("Keep silent parts where I click or type", isOn: $model.keepSilentDemos)
                .font(.callout)
            if !model.cutSuggestions.isEmpty { CutReview(model: model) }
        }
    }

    private var privacy: some View {
        InspectorSection("Privacy") {
            HStack {
                if let progress = model.privacyProgress {
                    ProgressView(value: progress) { Text("Scanning… \(Int(progress * 100))%").font(.caption) }
                } else {
                    Button("Scan & Blur Sensitive Info", action: model.scanPrivacy)
                        .help("Reads the screen on this Mac: emails, phone numbers, keys/tokens, names and faces")
                }
                Spacer()
                Button { model.addManualBlur() } label: { Image(systemName: "plus.square.dashed") }
                    .help("Add a blur box at the playhead")
            }
            .controlSize(.small)
            ForEach(BlurRegion.Kind.allCases) { kind in
                let count = model.blurCount(kind)
                if count.total > 0 {
                    Toggle(isOn: Binding(get: { count.enabled > 0 }, set: { model.setBlurs(kind, enabled: $0) })) {
                        HStack {
                            Text(kind.label)
                            Spacer()
                            Text("\(count.enabled)/\(count.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var social: some View {
        InspectorSection("Social") {
            HStack {
                Button { model.settings.aspect = .vertical; model.settings.reframe = true } label: { Label("9:16", systemImage: "rectangle.portrait") }
                Button { model.settings.aspect = .square; model.settings.reframe = true } label: { Label("1:1", systemImage: "square") }
                Spacer()
                Button { tab = .social } label: { Label("Shorts…", systemImage: "sparkles") }
                    .help("Make YouTube Shorts from this video in the Social tab")
            }
            .controlSize(.small)
        }
    }

    private func cornerButton(_ corner: CameraCorner) -> some View {
        let active = model.settings.cameraCorner == corner && model.settings.cameraX == nil
            && !(model.settings.cameraFollowsRecording && model.hasRecordedCameraPath)
        return Button { model.setCameraCorner(corner) } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 22, height: 14)
        }
        .buttonStyle(.plain)
    }

    private var captions: some View {
        InspectorSection("Captions") {
            Button {
                model.openSubtitleEditor?()
            } label: {
                Label("Edit & Correct Subtitles…", systemImage: "text.badge.checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help("All lines in one window: find & replace, brand glossary, Fix with Claude")
            HStack {
                Picker("Language", selection: $model.captionLanguage) {
                    ForEach(Captioner.languages, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 130)
                Spacer()
                if let progress = model.captionProgress {
                    ProgressView(value: progress).frame(width: 90)
                } else {
                    Button(model.captions.isEmpty ? "Generate" : "Regenerate", action: model.generateCaptions)
                }
            }
            if !model.captions.isEmpty {
                HStack {
                    Text("\(model.captions.count) captions. Click one in the timeline to edit its text.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive, action: model.removeCaptions).controlSize(.small)
                }
            } else {
                Text("Transcribes the voice track on this Mac and adds subtitles you can edit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var audio: some View {
        InspectorSection("Audio") {
            ForEach(model.audioLanes, id: \.self) { kind in
                HStack(spacing: 8) {
                    Button { model.toggleMute(kind) } label: {
                        Image(systemName: model.isMuted(kind) ? "speaker.slash.fill" : EditorModel.laneSymbol(kind))
                            .foregroundStyle(model.isMuted(kind) ? Color.red : Color.primary)
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .help(model.isMuted(kind) ? "Unmute" : "Mute")
                    Text(EditorModel.laneName(kind)).frame(width: 84, alignment: .leading)
                    Slider(value: Binding(get: { model.volume(kind) }, set: { model.setVolume(kind, $0) }), in: 0...1)
                        .disabled(model.isMuted(kind))
                    Text(model.isMuted(kind) ? "off" : "\(Int(model.volume(kind) * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    private var export: some View {
        InspectorSection("Export") {
            Picker("Resolution", selection: $model.settings.exportResolution) {
                ForEach(ExportResolution.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let progress = model.exportProgress {
                ProgressView(value: progress) { Text("Exporting… \(Int(progress * 100))%").font(.caption) }
            } else {
                Button(action: model.export) {
                    Label("Export MP4…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if model.lastExport != nil, model.exportProgress == nil {
                HStack {
                    Button("Show in Finder", action: model.revealExport)
                    Button("Copy File", action: model.copyExport)
                }
                .controlSize(.small)
            }
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var multiplier = 1.0

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, multiplier: Double = 1) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
        self.multiplier = multiplier
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value * multiplier))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

private struct Swatch: View {
    let preset: BackgroundPreset
    let selected: Bool

    var body: some View {
        ZStack {
            switch preset.kind {
            case .gradient(let colors):
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
            case .solid(let color):
                RoundedRectangle(cornerRadius: 9).fill(Color(hex: color))
            case .wallpaper:
                RoundedRectangle(cornerRadius: 9).fill(.quaternary)
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
        }
        .frame(width: 38, height: 38)
        .contentShape(Rectangle())
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let symbol: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                Spacer()
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ClipPanel: View {
    @ObservedObject var model: EditorModel
    let placement: EditorModel.Placement

    private static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        let clip = placement.clip
        let id = clip.id
        Panel(title: "Clip \(placement.index + 1) of \(model.clips.count)", symbol: clip.kind == .recording ? "record.circle" : "film",
              detail: "\(formatTime(placement.offset)) – \(formatTime(placement.end))") {
            TextField("Name", text: Binding(get: { clip.name }, set: { model.renameClip(id, $0) }))
                .textFieldStyle(.roundedBorder)
            Text("Uses \(formatTime(clip.start)) – \(formatTime(clip.end)) of \(formatTime(placement.media.info.duration))"
                 + (clip.kind == .video ? "  ·  video file, no cursor data" : ""))
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Speed").frame(width: 70, alignment: .leading)
                Picker("Speed", selection: Binding(get: { clip.speed }, set: { model.setSpeed(id, $0) })) {
                    ForEach(Self.speeds, id: \.self) { Text(TimelineView.speedLabel($0)).tag($0) }
                    if !Self.speeds.contains(clip.speed) { Text(TimelineView.speedLabel(clip.speed)).tag(clip.speed) }
                }
                .labelsHidden()
            }
            ForEach(model.audioKinds(of: placement), id: \.self) { kind in
                SliderRow(kind == "system-audio" ? "System" : EditorModel.laneName(kind),
                          value: Binding(get: { clip.volume(for: kind) }, set: { model.setClipVolume(id, kind: kind, $0) }),
                          range: 0...1, format: "%.0f%%", multiplier: 100)
            }
            if placement.media.info.webcam != nil {
                HStack {
                    Text("Camera").frame(width: 70, alignment: .leading)
                    Picker("Camera", selection: Binding(get: { clip.camera }, set: { model.setCameraLayout(id, $0) })) {
                        ForEach(Clip.CameraLayout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            if placement.index < model.clips.count - 1 {
                HStack {
                    Text("To next").frame(width: 70, alignment: .leading)
                    Picker("Transition", selection: Binding(get: { clip.transition?.kind }, set: { model.setTransition(id, $0) })) {
                        Text("Cut").tag(ClipTransition.Kind?.none)
                        ForEach(ClipTransition.Kind.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    .labelsHidden()
                }
                if let transition = clip.transition {
                    SliderRow("Duration", value: Binding(get: { transition.duration }, set: { model.setTransitionDuration(id, $0) }),
                              range: 0.2...2, format: "%.1fs")
                }
            }
            let typing = model.typingRanges(in: placement)
            if !typing.isEmpty {
                Button { model.speedUpTyping(id) } label: {
                    Label("Speed Up Typing (\(typing.count)× at \(TimelineView.speedLabel(model.settings.typingSpeed)))", systemImage: "keyboard")
                }
                .controlSize(.small)
            }
            HStack {
                Button("Start at Playhead", action: model.setClipStartToPlayhead)
                Button("End at Playhead", action: model.setClipEndToPlayhead)
            }
            .controlSize(.small)
            HStack {
                Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
                    .help("Split the clip under the playhead (B)")
                Button { model.duplicateClip(id) } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate (⌘D)")
                Button { model.moveSelectedClip(by: -1) } label: { Image(systemName: "arrow.left") }
                    .disabled(placement.index == 0).help("Move earlier")
                Button { model.moveSelectedClip(by: 1) } label: { Image(systemName: "arrow.right") }
                    .disabled(placement.index == model.clips.count - 1).help("Move later")
                Spacer()
                Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
                    .disabled(model.clips.count < 2).help("Remove clip (⌫)")
            }
            .controlSize(.small)
        }
    }
}

private struct TextPanel: View {
    @ObservedObject var model: EditorModel
    let text: TextOverlay

    private let colors: [UInt32] = [0xFFFFFF, 0x1C1C1E, 0x7F5AF0, 0x2CB1BC, 0xFFD60A, 0xFF453A, 0x30D158]
    private let positions: [(x: Double, y: Double)] = [(0.2, 0.15), (0.5, 0.15), (0.8, 0.15),
                                                        (0.2, 0.5), (0.5, 0.5), (0.8, 0.5),
                                                        (0.2, 0.85), (0.5, 0.85), (0.8, 0.85)]

    var body: some View {
        Panel(title: text.caption ? "Subtitle" : "Text", symbol: text.caption ? "captions.bubble" : "textformat",
              detail: "\(formatTime(text.start)) – \(formatTime(text.end))") {
            if text.caption {
                Button { model.openSubtitleEditor?() } label: {
                    Label("Edit & Correct All Subtitles…", systemImage: "text.badge.checkmark").frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                Button { model.applyCaptionStyle(from: text.id) } label: {
                    Label("Use This Style for All Subtitles", systemImage: "paintbrush").frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("Size, position, style, colours and font of this line for every subtitle, including regenerated ones")
            }
            TextEditor(text: Binding(get: { text.text }, set: { v in model.updateText(text.id) { $0.text = v } }))
                .font(.body)
                .frame(height: 54)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            SliderRow("Size", value: Binding(get: { text.size }, set: { v in model.updateText(text.id) { $0.size = v } }),
                      range: 0.02...0.16, format: "%.0f", multiplier: 1000)
            Picker("Style", selection: Binding(get: { text.style }, set: { v in model.updateText(text.id) { $0.style = v } })) {
                ForEach(TextOverlay.Style.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 7) {
                ForEach(colors, id: \.self) { color in
                    Button { model.updateText(text.id) { $0.color = color } } label: {
                        Circle().fill(Color(hex: color)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(text.color == color ? Color.accentColor : Color.primary.opacity(0.2),
                                                           lineWidth: text.color == color ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .top) {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(0..<3) { row in
                        GridRow {
                            ForEach(0..<3) { column in
                                let p = positions[row * 3 + column]
                                let active = abs(text.x - p.x) < 0.02 && abs(text.y - p.y) < 0.02
                                Button { model.updateText(text.id) { $0.x = p.x; $0.y = p.y } } label: {
                                    RoundedRectangle(cornerRadius: 2).fill(active ? Color.accentColor : Color.secondary.opacity(0.35))
                                        .frame(width: 16, height: 11)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text("Pick a spot, or drag the text on the preview.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Start at Playhead") { let t = model.currentTime; model.updateText(text.id) { $0.end += t - $0.start; $0.start = t } }
                Button("End at Playhead") { let t = model.currentTime; model.updateText(text.id) { $0.end = t } }
                Spacer()
                Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
            }
            .controlSize(.small)
        }
    }
}

private struct SelectedZoomPanel: View {
    @ObservedObject var model: EditorModel
    let zoom: EditorModel.PlacedZoom
    @State private var frame: CGImage?

    private enum FocusMode: Hashable { case cursor, fixed }

    var body: some View {
        let segment = zoom.segment
        Panel(title: "Zoom", symbol: segment.focus == nil ? "plus.magnifyingglass" : "scope",
              detail: "\(formatTime(zoom.start)) – \(formatTime(zoom.end))") {
            SliderRow("Level", value: Binding(get: { segment.zoom }, set: { v in model.updateSelectedZoom { $0.zoom = v } }),
                      range: 1.1...4, format: "%.1f×")

            Picker("Focus", selection: Binding(
                get: { segment.focus == nil ? FocusMode.cursor : .fixed },
                set: { mode in model.setSelectedFocus(mode == .cursor ? nil : model.defaultFocus(for: zoom)) }
            )) {
                Label("Follow cursor", systemImage: "cursorarrow.motionlines").tag(FocusMode.cursor)
                Label("Fixed point", systemImage: "scope").tag(FocusMode.fixed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if zoom.placement.media.kind == .video, segment.focus == nil {
                Text("Video files have no cursor data, so this zoom stays centred. Pick a fixed point instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let focus = segment.focus {
                let size = zoom.placement.media.sourceSize
                FocusPicker(image: frame, aspect: size.width / max(1, size.height),
                            visible: model.visibleFraction(zoom: segment.zoom, in: zoom.placement),
                            point: focus) { model.setSelectedFocus($0) }
                    .task(id: segment.id) { frame = await model.sourceFrame(of: zoom.placement, at: (segment.start + segment.end) / 2) }
                HStack {
                    Text("Drag the frame to choose what the zoom shows.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Center") { model.setSelectedFocus(CGPoint(x: 0.5, y: 0.5)) }.controlSize(.mini)
                }
            }

            HStack {
                Toggle("Enabled", isOn: Binding(get: { segment.enabled }, set: { v in model.updateSelectedZoom { $0.enabled = v } }))
                Spacer()
                Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
                    .controlSize(.small)
            }
        }
    }
}

private struct AISection: View {
    @ObservedObject var model: EditorModel
    private let examples = ["Remove all pauses", "Zoom in when I open the settings", "Add a title “KI-Update” at the start",
                            "Speed up the part where I type", "Camera top-left after 0:10"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Edit with AI", systemImage: "sparkles").font(.subheadline.weight(.semibold))
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Describe an edit…", text: $model.aiPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(model.runAIPrompt)
                Button(action: model.runAIPrompt) {
                    if model.aiBusy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                }
                .buttonStyle(.plain)
                .disabled(model.aiBusy || model.aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let status = model.aiStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let status = model.analysisStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(examples, id: \.self) { example in
                            Button(example) { model.aiPrompt = example }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(LinearGradient(colors: [Color(hex: 0x7F5AF0).opacity(0.18), Color(hex: 0x2CB1BC).opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CameraKeyPanel: View {
    @ObservedObject var model: EditorModel
    let key: CameraKey

    var body: some View {
        Panel(title: "Camera Keyframe", symbol: "video", detail: formatTime(key.t)) {
            Picker("Layout", selection: Binding(get: { key.layout ?? .overlay }, set: { v in model.updateCameraKey(key.id) { $0.layout = v } })) {
                ForEach(Clip.CameraLayout.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 5) {
                ForEach(TimelineView.positions, id: \.name) { item in
                    Button(item.name.replacingOccurrences(of: " ", with: "\n")) { model.updateCameraKey(key.id) { $0.x = item.x; $0.y = item.y } }
                        .font(.caption2)
                        .controlSize(.small)
                }
            }
            Text("Or move the playhead here and drag the camera on the preview. It glides to each keyframe over half a second.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Move to Playhead") { let t = model.currentTime; model.updateCameraKey(key.id) { $0.t = t } }
                Spacer()
                Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
            }
            .controlSize(.small)
        }
    }
}

private struct BlurPanel: View {
    @ObservedObject var model: EditorModel
    let region: BlurRegion
    @State private var frame: CGImage?

    var body: some View {
        Panel(title: region.kind == .manual ? "Blur Box" : "Blurred \(region.kind.label.lowercased())", symbol: "eye.slash",
              detail: "\(formatTime(region.start)) – \(formatTime(region.end))") {
            if let label = region.label, region.kind != .manual {
                Text(label).font(.caption.monospaced()).lineLimit(2)
            }
            Toggle("Blurred", isOn: Binding(get: { region.enabled }, set: { v in model.updateBlur(region.id) { $0.enabled = v } }))
            if let placement = model.placements.first(where: { $0.clip.source == region.source }) {
                let size = placement.media.sourceSize
                FocusPicker(image: frame, aspect: size.width / max(1, size.height), visible: CGSize(width: region.w, height: region.h),
                            point: CGPoint(x: region.x + region.w / 2, y: region.y + region.h / 2)) { p in
                    model.updateBlur(region.id) { $0.x = p.x - $0.w / 2; $0.y = p.y - $0.h / 2 }
                }
                .task(id: region.id) { frame = await model.sourceFrame(of: placement, at: (region.start + region.end) / 2) }
                SliderRow("Width", value: Binding(get: { region.w }, set: { v in model.updateBlur(region.id) { $0.w = v } }),
                          range: 0.02...1, format: "%.0f%%", multiplier: 100)
                SliderRow("Height", value: Binding(get: { region.h }, set: { v in model.updateBlur(region.id) { $0.h = v } }),
                          range: 0.02...1, format: "%.0f%%", multiplier: 100)
            }
            HStack {
                Button("Start at Playhead") {
                    if let p = model.placement(at: model.currentTime) { let s = p.sourceTime(model.currentTime); model.updateBlur(region.id) { $0.start = s } }
                }
                Button("End at Playhead") {
                    if let p = model.placement(at: model.currentTime) { let s = p.sourceTime(model.currentTime); model.updateBlur(region.id) { $0.end = s } }
                }
                Spacer()
                Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
            }
            .controlSize(.small)
        }
    }
}

/// A one-click AI action in the AI tab.
private struct ActionCard: View {
    let symbol: String
    let title: String
    let detail: String
    var enabled = true
    var progress: Double? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.accentColor)
                    Spacer()
                    if progress != nil { ProgressView().controlSize(.mini) }
                }
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || progress != nil)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// Proposed cuts waiting for Apply (shared by the AI and Audio tabs).
private struct CutReview: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let total = model.cutSuggestions.reduce(0) { $0 + $1.end - $1.start }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "scissors").foregroundStyle(.red)
                Text("\(model.cutSuggestions.count) cuts · saves \(formatDuration(total))").font(.callout.weight(.medium))
                Spacer()
                Button("Clear", action: model.clearCuts).controlSize(.small)
                Button("Apply", action: model.applyCuts).controlSize(.small).buttonStyle(.borderedProminent)
            }
            Text("Red on the timeline will be cut. Click a red strip to keep that part.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct EmptyState: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
