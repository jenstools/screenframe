import SwiftUI

// MARK: Transcript

/// The transcript as clickable words: click to jump there, shift-click to select a stretch,
/// ⌫ or "Cut" removes it from the video. The word being spoken is highlighted.
struct TranscriptPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let words = model.transcriptWords
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SCRIPT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("Language", selection: $model.captionLanguage) {
                    ForEach(Captioner.languages, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
            }
            if words.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.quote").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Edit the video by editing its text: transcribe the voice (on this Mac), then delete words to cut them.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let progress = model.progress(of: "words") {
                        ProgressView(value: progress) { Text("Transcribing… \(Int(progress * 100))%").font(.caption) }
                            .frame(width: 200)
                    } else {
                        Button("Transcribe", action: model.transcribe).buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                if let range = model.transcriptSelection {
                    HStack {
                        Text("\(range.count) word\(range.count == 1 ? "" : "s") selected").font(.callout.weight(.medium))
                        Spacer()
                        Button("Deselect") { model.transcriptSelection = nil }.controlSize(.small)
                        Button { model.cutTranscriptSelection() } label: { Label("Cut", systemImage: "scissors") }
                            .controlSize(.small).buttonStyle(.borderedProminent).tint(.red)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Click a word to jump there · shift-click to select · ⌫ cuts the selection")
                        .font(.caption).foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 3, lineSpacing: 5) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                        let previous = i > 0 ? words[i - 1] : nil
                        if let previous, word.start - previous.end > 1.2 {
                            // Long pause: a visible gap you can see (and cut with Clean up).
                            Text("⏸ \(String(format: "%.1f", word.start - previous.end)) s")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                        }
                        WordToken(word: word, selected: model.transcriptSelection?.contains(i) ?? false,
                                  current: model.currentTime >= word.start && model.currentTime < word.end + 0.15)
                            .onTapGesture { model.selectWord(i, extend: NSEvent.modifierFlags.contains(.shift)) }
                    }
                }
            }
        }
    }
}

private struct WordToken: View {
    let word: Captioner.Word
    let selected: Bool
    let current: Bool

    var body: some View {
        Text(word.text)
            .font(.system(size: 13))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(selected ? Color.red.opacity(0.35) : current ? Color.accentColor.opacity(0.3) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .strikethrough(selected, color: .red)
            .contentShape(Rectangle())
    }
}

/// Wraps its children like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: Brand kit

struct BrandKitSection: View {
    @ObservedObject var model: EditorModel
    @AppStorage("brandKit") private var selectedKit = ""

    var body: some View {
        let kit = model.brandKits.first { $0.id.uuidString == selectedKit } ?? model.brandKits.first
        VStack(alignment: .leading, spacing: 10) {
            Text("BRAND KIT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Picker("Kit", selection: Binding(get: { kit?.id.uuidString ?? "" }, set: { selectedKit = $0 })) {
                    ForEach(model.brandKits) { Text($0.name).tag($0.id.uuidString) }
                }
                .labelsHidden()
                if let kit {
                    HStack(spacing: 2) {
                        ForEach(kit.gradient + [kit.accentColor], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 12, height: 12) }
                    }
                }
            }
            HStack {
                Button {
                    if let kit { model.applyBrandKit(kit) }
                } label: {
                    Label(model.applyingBrand ? "Applying…" : "Apply Kit", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(kit == nil || model.applyingBrand)
                Button("Edit Kits…") { model.activeSheet = .brandKits }
            }
            .controlSize(.small)
            Text("Background, fonts and colours, logo, lower third, intro and outro, in one click.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BrandKitSheet: View {
    @ObservedObject var model: EditorModel
    @State private var index = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Brand Kits").font(.title3.bold())
                Spacer()
                Button { addKit() } label: { Label("New Kit", systemImage: "plus") }
            }
            if model.brandKits.indices.contains(index) {
                HStack(alignment: .top, spacing: 18) {
                    List(selection: Binding(get: { index }, set: { index = $0 ?? 0 })) {
                        ForEach(Array(model.brandKits.enumerated()), id: \.offset) { i, kit in Text(kit.name).tag(i) }
                    }
                    .frame(width: 150, height: 330)
                    form(for: index)
                }
            }
            HStack {
                if model.brandKits.count > 1 {
                    Button("Delete Kit", role: .destructive) {
                        model.brandKits.remove(at: index)
                        index = 0
                        model.saveBrandKits()
                    }
                }
                Spacer()
                Button("Done") {
                    model.saveBrandKits()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func form(for i: Int) -> some View {
        Form {
            TextField("Name", text: $model.brandKits[i].name)
            HStack {
                Text("Gradient")
                ColorWell(value: Binding(get: { model.brandKits[i].gradient.first ?? 0 }, set: { model.brandKits[i].gradient[0] = $0 }))
                ColorWell(value: Binding(get: { model.brandKits[i].gradient.last ?? 0 }, set: {
                    if model.brandKits[i].gradient.count < 2 { model.brandKits[i].gradient.append($0) } else { model.brandKits[i].gradient[1] = $0 }
                }))
                Text("Text").padding(.leading, 8)
                ColorWell(value: $model.brandKits[i].textColor)
                Text("Accent").padding(.leading, 8)
                ColorWell(value: $model.brandKits[i].accentColor)
            }
            Picker("Font", selection: $model.brandKits[i].font) {
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Text("Logo")
                if let path = model.brandKits[i].logoPath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 26)
                        .padding(4).background(Color.gray.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                }
                Button("Choose…") { model.chooseLogo(for: i) }
                if model.brandKits[i].logoPath != nil { Button("Remove") { model.brandKits[i].logoPath = nil } }
                Picker("Corner", selection: $model.brandKits[i].logoCorner) {
                    Text("Top left").tag(CameraCorner.topLeft)
                    Text("Top right").tag(CameraCorner.topRight)
                    Text("Bottom left").tag(CameraCorner.bottomLeft)
                    Text("Bottom right").tag(CameraCorner.bottomRight)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            TextField("Lower third: name", text: $model.brandKits[i].lowerThirdName)
            TextField("Lower third: title", text: $model.brandKits[i].lowerThirdTitle)
            TextField("Intro card text (empty = none)", text: $model.brandKits[i].introText)
            TextField("Outro card text (empty = none)", text: $model.brandKits[i].outroText)
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }

    private func addKit() {
        var kit = BrandKitStore.defaultKit()
        kit.id = UUID()
        kit.name = "New Kit"
        model.brandKits.append(kit)
        index = model.brandKits.count - 1
    }
}

/// A colour picker bound to a 0xRRGGBB value.
private struct ColorWell: View {
    @Binding var value: UInt32

    var body: some View {
        ColorPicker("", selection: Binding(get: { Color(hex: value) }, set: { color in
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            value = (UInt32(ns.redComponent * 255) << 16) | (UInt32(ns.greenComponent * 255) << 8) | UInt32(ns.blueComponent * 255)
        }), supportsOpacity: false)
        .labelsHidden()
        .frame(width: 34)
    }
}

// MARK: Content package

struct ContentSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Content Package", systemImage: "doc.richtext").font(.title3.bold())
                Spacer()
                if let folder = model.lastOutputFolder, model.contentPackage != nil {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                Button("Regenerate", action: model.generateContentPackage).disabled(model.contentBusy)
            }
            if model.contentBusy {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Transcribing and writing… (Claude)").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else if let package = model.contentPackage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        block("Title ideas", package.titles.map { "• \($0)" }.joined(separator: "\n"))
                        block("Chapters", package.chapters.map { "\(formatDuration($0.t)) \($0.title)" }.joined(separator: "\n"))
                        block("LinkedIn post", package.linkedin)
                        block("YouTube description", package.youtube)
                        block("Newsletter snippet", package.newsletter)
                        block("Hashtags", package.hashtags.map { "#\($0)" }.joined(separator: " "))
                    }
                }
                Text("Saved to the project's content folder (content.md, chapters.txt, captions.srt).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Nothing generated yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 640, height: 640)
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .controlSize(.small)
            }
            Text(text).textSelection(.enabled).font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: Thumbnails

struct ThumbnailSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Double?
    @State private var headline = ""
    @State private var kitID = ""
    @State private var faceCutout = true
    @State private var preview: CGImage?
    @State private var previewTask: Task<Void, Never>?

    private var kit: BrandKit? { model.brandKits.first { $0.id.uuidString == kitID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Thumbnail", systemImage: "photo.on.rectangle").font(.title3.bold())
            if model.thumbnailCandidates.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Finding strong frames…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text("Pick a frame").font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    ForEach(model.thumbnailCandidates) { candidate in
                        Image(decorative: candidate.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(picked == candidate.time ? Color.accentColor : .clear, lineWidth: 3))
                            .onTapGesture { picked = candidate.time; refresh() }
                    }
                }
            }
            HStack {
                TextField("Headline", text: $headline).textFieldStyle(.roundedBorder).onSubmit(refresh)
                Button("Suggest") { Task { headline = await model.suggestHeadline(); refresh() } }
            }
            HStack {
                Picker("Style", selection: $kitID) {
                    Text("No brand").tag("")
                    ForEach(model.brandKits) { Text($0.name).tag($0.id.uuidString) }
                }
                .frame(width: 220)
                Toggle("Cut me out of the camera", isOn: $faceCutout).disabled(!model.hasWebcam)
                Spacer()
            }
            .onChange(of: kitID) { _, _ in refresh() }
            .onChange(of: faceCutout) { _, _ in refresh() }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                } else if picked != nil {
                    ProgressView()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            HStack {
                Text("Exports YouTube 16:9, LinkedIn 1.91:1 and square PNGs into the project's thumbnails folder.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                Button("Export PNGs") {
                    if let picked { model.exportThumbnails(at: picked, headline: headline, kit: kit, faceCutout: faceCutout) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked == nil || model.thumbnailBusy)
            }
        }
        .padding(20)
        .frame(width: 720)
        .task {
            kitID = model.brandKits.first { model.settings.customGradient == $0.gradient }?.id.uuidString ?? ""
            if headline.isEmpty { headline = await model.suggestHeadline() }
        }
        .onChange(of: model.thumbnailCandidates.count) { _, _ in
            if picked == nil { picked = model.thumbnailCandidates.first?.time; refresh() }
        }
    }

    private func refresh() {
        guard let picked else { return }
        previewTask?.cancel()
        let project = model.snapshot, headline = self.headline, kit = self.kit, cutout = faceCutout && model.hasWebcam
        previewTask = Task {
            let image = try? await ThumbnailMaker.compose(project: project, at: picked, headline: headline, kit: kit,
                                                          faceCutout: cutout, format: .youtube)
            if !Task.isCancelled { preview = image }
        }
    }
}

// MARK: Activity strip

/// What's running right now, on top of the preview: one card per task with progress and how long
/// it has been going, then a short confirmation when it's done. Starting a running task again
/// only shows a notice, so double-clicks never start work twice.
struct ActivityStrip: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.activities) { activity in
                HStack(spacing: 10) {
                    if let progress = activity.progress, progress > 0 {
                        ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(activity.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let progress = activity.progress, progress > 0 {
                        Text("\(Int(progress * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsed(since: activity.started)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: 460)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35)))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let toast = model.toast {
                Label(toast, systemImage: toast.hasPrefix("Already") ? "hourglass" : "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(toast.hasPrefix("Already") ? Color.orange : Color.green)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 12)
        .animation(.spring(duration: 0.35), value: model.activities)
        .animation(.spring(duration: 0.35), value: model.toast)
        .allowsHitTesting(false)
    }

    private func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        return seconds < 60 ? "\(seconds) s" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
