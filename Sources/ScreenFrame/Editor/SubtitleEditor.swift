import SwiftUI

/// All subtitles in one window, next to the editor: edit every line, find & replace across all,
/// a brand glossary that also teaches the recognizer, a Claude proofreading pass, and one style
/// for all captions. Every change is live in the editor and undoable there.
struct SubtitleEditorView: View {
    @ObservedObject var model: EditorModel
    @State private var find = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var wholeWord = true
    @State private var onlyFixed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.captions.isEmpty {
                emptyState
            } else {
                findBar
                styleBar
                Divider()
                HStack(spacing: 0) {
                    captionList
                    Divider()
                    GlossaryPanel(model: model).frame(width: 270)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 640)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Label("Subtitles", systemImage: "captions.bubble").font(.title3.bold())
            if !model.captions.isEmpty {
                Text("\(model.captions.count) lines").foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Language", selection: $model.captionLanguage) {
                ForEach(Captioner.languages, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 120)
            if let progress = model.progress(of: "captions") {
                ProgressView(value: progress).frame(width: 90)
            } else {
                Button(model.captions.isEmpty ? "Generate" : "Regenerate", action: model.generateCaptions)
                    .help("Transcribe the voice again (uses the glossary)")
            }
            Button {
                model.fixSubtitlesWithClaude()
            } label: {
                if model.isRunning("subfix") {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Fix with Claude", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.captions.isEmpty || model.isRunning("subfix"))
            .help("Corrects misheard words, brand names, spelling and punctuation. Never rewords. ⌘Z in the editor undoes.")
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "captions.bubble").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("No subtitles yet.").font(.headline)
            Text("Generate them from the voice track. Brand names from the glossary on the right are recognized better and fixed automatically.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Generate Subtitles", action: model.generateCaptions).buttonStyle(.borderedProminent)
                .disabled(model.isRunning("captions"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Find & replace

    private var findBar: some View {
        let matches = model.matchCount(find, caseSensitive: caseSensitive, wholeWord: wholeWord)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find (e.g. Screen Free)", text: $find).textFieldStyle(.roundedBorder).frame(width: 200)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            TextField("Replace with (e.g. ScreenFrame)", text: $replacement).textFieldStyle(.roundedBorder).frame(width: 200)
            Toggle("Aa", isOn: $caseSensitive).toggleStyle(.button).help("Match case")
            Toggle("Word", isOn: $wholeWord).toggleStyle(.button).help("Whole words only")
            Text(find.isEmpty ? "" : "\(matches) match\(matches == 1 ? "" : "es")")
                .font(.caption.monospacedDigit()).foregroundStyle(matches > 0 ? Color.orange : .secondary)
                .frame(width: 74, alignment: .leading)
            Button("Replace All") { model.replaceAll(find, with: replacement, caseSensitive: caseSensitive, wholeWord: wholeWord) }
                .disabled(find.isEmpty || matches == 0)
            Button {
                model.learn(find, as: replacement)
            } label: {
                Label("Add to Glossary", systemImage: "book.closed")
            }
            .disabled(replacement.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Remember this correction: future transcriptions fix it automatically")
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Style for all

    private var styleBar: some View {
        let current = model.captionStyle
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("All subtitles:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Style", selection: Binding(get: { current.style }, set: { v in model.styleAllCaptions { $0.style = v } })) {
                    ForEach(TextOverlay.Style.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Picker("Position", selection: Binding(get: { current.y < 0.5 ? 0.1 : 0.9 }, set: { v in model.styleAllCaptions { $0.y = v } })) {
                    Text("Bottom").tag(0.9)
                    Text("Top").tag(0.1)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                HStack(spacing: 4) {
                    Text("Size").font(.caption)
                    Slider(value: Binding(get: { current.size }, set: { v in model.styleAllCaptions { $0.size = v } }), in: 0.025...0.08)
                        .frame(width: 110)
                }
                HStack(spacing: 4) {
                    Text("Width").font(.caption)
                    Slider(value: Binding(get: { current.wrapWidth ?? 0.88 }, set: { v in model.styleAllCaptions { $0.wrapWidth = v } }),
                           in: 0.4...0.95)
                        .frame(width: 90)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Picker("Font", selection: Binding(get: { current.fontName }, set: { v in model.styleAllCaptions { $0.fontName = v } })) {
                    Text("System").tag(String?.none)
                    ForEach(fonts(including: current.fontName), id: \.name) { Text($0.label).tag(Optional($0.name)) }
                }
                .frame(width: 210)
                HStack(spacing: 4) {
                    Text("Text").font(.caption)
                    ForEach(Self.textColors, id: \.self) { color in
                        swatch(color, selected: current.color == color) { model.styleAllCaptions { $0.color = color } }
                    }
                }
                HStack(spacing: 4) {
                    Text("Background").font(.caption)
                    Button { model.styleAllCaptions { $0.pillColor = nil } } label: {
                        Text("Auto").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(current.pillColor == nil ? Color.accentColor : Color.primary.opacity(0.25),
                                                            lineWidth: current.pillColor == nil ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    ForEach(Self.pillColors, id: \.self) { color in
                        swatch(color, selected: current.pillColor == color) { model.styleAllCaptions { $0.pillColor = color } }
                    }
                }
                .disabled(current.style != .pill)
                .opacity(current.style == .pill ? 1 : 0.4)
                .help("Background of the pill style")
                Spacer()
                if !model.recentlyFixed.isEmpty {
                    Toggle("Only Claude's changes (\(model.recentlyFixed.count))", isOn: $onlyFixed).toggleStyle(.checkbox)
                    let learnable = model.learnableFixes
                    if !learnable.isEmpty {
                        Button {
                            model.learnFromFixes()
                        } label: {
                            Label("Learn \(learnable.count) for next time", systemImage: "graduationcap")
                        }
                        .help(learnable.map { "\($0.heard) → \($0.term)" }.joined(separator: "\n"))
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private static let textColors: [UInt32] = [0xFFFFFF, 0xFFD60A, 0x71D4A9, 0x1C1C1E]
    private static let pillColors: [UInt32] = [0x1C1C1E, 0xFFFFFF, 0x7F5AF0, 0x2CB1BC, 0xFF453A]

    private func swatch(_ color: UInt32, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(Color(hex: color)).frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
    }

    /// Brand kit fonts first, then a few installed bold faces; the current font is always listed.
    private func fonts(including current: String?) -> [(name: String, label: String)] {
        var names = model.brandKits.map(\.fontPostScriptName)
        names += ["AvenirNext-Bold", "HelveticaNeue-Bold", "Futura-Bold", "GillSans-Bold", "Georgia-Bold", "Menlo-Bold"]
        if let current { names.insert(current, at: 0) }
        var seen = Set<String>()
        return names.compactMap { name in
            guard seen.insert(name).inserted, let font = NSFont(name: name, size: 12) else { return nil }
            return (name, font.displayName ?? name)
        }
    }

    // MARK: Lines

    private var captionList: some View {
        let lines = model.sortedCaptions.filter { !onlyFixed || model.recentlyFixed.contains($0.id) }
        let current = lines.first { model.currentTime >= $0.start && model.currentTime < $0.end }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(lines) { line in
                        CaptionRow(model: model, line: line, current: line.id == current, fixed: model.recentlyFixed.contains(line.id),
                                   highlight: !find.isEmpty && line.text.range(of: find, options: caseSensitive ? [] : .caseInsensitive) != nil)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: current) { _, id in
                if let id, model.isPlaying { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct CaptionRow: View {
    @ObservedObject var model: EditorModel
    let line: TextOverlay
    let current: Bool
    let fixed: Bool
    let highlight: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.playCaption(line) } label: {
                HStack(spacing: 4) {
                    Image(systemName: current && model.isPlaying ? "speaker.wave.2.fill" : "play.fill").font(.system(size: 9))
                    Text(formatTime(line.start)).font(.caption.monospacedDigit())
                }
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(current ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Play from here")
            TextField("", text: Binding(get: { line.text }, set: { value in model.updateText(line.id) { $0.text = value } }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...4)
            if fixed {
                Image(systemName: "sparkles").foregroundStyle(Color(hex: 0x7F5AF0)).help("Changed by Claude")
            }
            Button { model.mergeCaptionWithNext(line.id) } label: { Image(systemName: "arrow.down.to.line") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Merge with the next line")
            Button { model.deleteCaption(line.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete this subtitle")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(current ? Color.accentColor.opacity(0.14) : fixed ? Color(hex: 0x7F5AF0).opacity(0.08) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(highlight ? Color.orange.opacity(0.8) : .clear, lineWidth: 1.5))
    }
}

/// Brand names and terms: what it should say, and what the recognizer hears instead.
struct GlossaryPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Glossary", systemImage: "book.closed").font(.headline)
                Spacer()
                Button { model.glossary.append(GlossaryEntry(term: "")) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add a term")
            }
            Text("Correct spelling, and what it's often misheard as (comma-separated). Used for every transcription in every project.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($model.glossary) { $entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("Term, e.g. snipKI", text: $entry.term).textFieldStyle(.roundedBorder).font(.callout.weight(.semibold))
                                Button { model.glossary.removeAll { $0.id == entry.id }; model.saveGlossary() } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                            TextField("Heard as: snip KI, Schnipp KI", text: Binding(
                                get: { entry.variants.joined(separator: ", ") },
                                set: { entry.variants = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            Button {
                model.applyGlossary()
            } label: {
                Label("Apply to All Subtitles", systemImage: "checkmark.seal").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .onDisappear { model.saveGlossary() }
    }
}
