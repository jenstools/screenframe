import AppKit

/// Transcript editing, brand kits and the publishing tools (content package, thumbnails, guide).
extension EditorModel {
    // MARK: Transcript

    /// Every spoken word in timeline time, in order.
    var transcriptWords: [Captioner.Word] {
        placements.flatMap { p -> [Captioner.Word] in
            guard let track = Cleanup.voiceTrack(of: p) ?? p.media.info.audio.first,
                  let words = wordsByFile[p.media.folder.appendingPathComponent(track.file).path] else { return [] }
            return words.compactMap { w in
                let s0 = w.start + track.offset, s1 = w.end + track.offset
                guard s0 >= p.clip.start, s1 <= p.clip.end + 0.2 else { return nil }
                return Captioner.Word(text: w.text, start: p.timelineTime(s0), end: min(p.end, p.timelineTime(s1)))
            }
        }
        .sorted { $0.start < $1.start }
    }

    var hasTranscript: Bool { !transcriptWords.isEmpty }

    func transcribe() {
        guard !transcribing else { show("Already transcribing"); return }
        Task {
            do { try await ensureWords() } catch { errorMessage = error.localizedDescription }
            let count = transcriptWords.count
            show(count == 0 ? "No speech found in this project" : "Transcribed \(count) words")
        }
    }

    /// Click a word: select it (shift-click extends) and jump there.
    func selectWord(_ index: Int, extend: Bool) {
        let words = transcriptWords
        guard words.indices.contains(index) else { return }
        if extend, let current = transcriptSelection {
            transcriptSelection = min(current.lowerBound, index)...max(current.upperBound, index)
        } else {
            transcriptSelection = index...index
        }
        seek(to: words[index].start)
    }

    /// Deletes the selected words from the video (cuts from the first word's start to the last's end).
    func cutTranscriptSelection() {
        let words = transcriptWords
        guard let range = transcriptSelection, words.indices.contains(range.lowerBound), words.indices.contains(range.upperBound) else { return }
        // Cut into the pause before, but not into neighbouring words.
        let before = range.lowerBound > 0 ? words[range.lowerBound - 1].end : 0
        let after = range.upperBound + 1 < words.count ? words[range.upperBound + 1].start : totalDuration
        let start = max(before, words[range.lowerBound].start - 0.08)
        let end = min(after, words[range.upperBound].end + 0.08)
        transcriptSelection = nil
        content = EditOps.remove([start...end], from: content, project: snapshot)
        seek(to: start)
    }

    // MARK: Brand kits

    func saveBrandKits() { BrandKitStore.save(brandKits) }

    /// Applies a kit: background gradient, fonts and colours on titles and captions, logo watermark,
    /// a lower third, and rendered intro/outro clips (re-applying replaces earlier brand elements).
    func applyBrandKit(_ kit: BrandKit) {
        guard begin("brand", "Applying “\(kit.name)”…") else { return }
        Task {
            defer { end("brand") }
            var s = settings
            s.background = "custom"
            s.customGradient = kit.gradient
            s.watermark = kit.logoPath.map { Watermark(path: $0, corner: kit.logoCorner, size: kit.logoSize, opacity: 0.9) }
            let font = kit.fontPostScriptName

            var newTexts = texts.filter { $0.brand != true }
            for i in newTexts.indices {
                newTexts[i].fontName = font
                if !newTexts[i].caption {
                    newTexts[i].color = kit.textColor
                    newTexts[i].pillColor = kit.accentColor
                }
            }

            var newClips = clips.filter { !$0.name.hasPrefix("Brand ") }
            let size = CGSize(width: 1920, height: 1080)
            do {
                for (label, text) in [("intro", kit.introText), ("outro", kit.outroText)] where !text.isEmpty {
                    let relative = "media/brand-\(label)-\(UUID().uuidString).mp4"
                    let url = project.url.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await CardRenderer.render(text: text, kit: kit, size: size, to: url)
                    var card = Clip(kind: .video, source: relative, name: "Brand \(label)", start: 0, end: 2.5,
                                    width: size.width, height: size.height, sourceDuration: 2.5)
                    card.isCard = true
                    if label == "intro" {
                        card.transition = ClipTransition(kind: .crossfade, duration: 0.5)
                        newClips.insert(card, at: 0)
                    } else {
                        if !newClips.isEmpty { newClips[newClips.count - 1].transition = ClipTransition(kind: .crossfade, duration: 0.5) }
                        newClips.append(card)
                    }
                }
            } catch {
                errorMessage = "Couldn't render the intro/outro: \(error.localizedDescription)"
            }

            settings = s
            clips = newClips
            // Lower third over the first seconds of the main content.
            let introLength = newClips.first?.name == "Brand intro" ? 2.5 : 0
            if !kit.lowerThirdName.isEmpty {
                let line = kit.lowerThirdTitle.isEmpty ? kit.lowerThirdName : "\(kit.lowerThirdName)\n\(kit.lowerThirdTitle)"
                newTexts.append(TextOverlay(text: line, start: introLength + 0.5, end: introLength + 5.5, x: 0.2, y: 0.86, size: 0.034,
                                            color: kit.textColor, style: .pill, fontName: font, pillColor: kit.accentColor,
                                            brand: true, wrapWidth: 0.4))
            }
            texts = newTexts
            analysisStatus = "Applied “\(kit.name)”."
        }
    }

    func chooseLogo(for index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .svg, .pdf]
        guard panel.runModal() == .OK, let url = panel.url, let path = BrandKitStore.importLogo(url),
              brandKits.indices.contains(index) else { return }
        brandKits[index].logoPath = path
        saveBrandKits()
    }

    // MARK: Content package

    func generateContentPackage() {
        activeSheet = .content
        guard begin("content", "Claude is writing your content package…") else { return }
        Task {
            defer { end("content") }
            do {
                try await ensureWords()
                let lines = transcriptLines()
                guard !lines.isEmpty else {
                    errorMessage = "There's no speech in this project to write from."
                    return
                }
                let package = try await ContentPackager.generate(lines: lines, duration: totalDuration, name: name, language: captionLanguage)
                contentPackage = package
                let captionLines = captions.isEmpty ? lines : captions.map { Captioner.Word(text: $0.text, start: $0.start, end: $0.end) }
                lastOutputFolder = try ContentPackager.save(package, captions: captionLines, name: name, in: project.url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Thumbnails

    func openThumbnails() {
        activeSheet = .thumbnail
        guard thumbnailCandidates.isEmpty, begin("thumbnail", "Finding strong thumbnail frames…") else { return }
        let project = snapshot
        Task {
            defer { end("thumbnail") }
            do { thumbnailCandidates = try await ThumbnailMaker.candidates(project: project) } catch { errorMessage = error.localizedDescription }
        }
    }

    /// A headline suggestion from the transcript (Claude), else the project name.
    func suggestHeadline() async -> String {
        try? await ensureWords()
        let lines = transcriptLines()
        guard !lines.isEmpty, let answer = try? await AIClient.ask(
            system: "Write ONE thumbnail headline for this video: max 5 words, punchy, the transcript's language. Answer with only the headline.",
            prompt: lines.map(\.text).joined(separator: " ")) else { return name }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"„“")))
    }

    func exportThumbnails(at time: Double, headline: String, kit: BrandKit?, faceCutout: Bool) {
        guard begin("thumbnail", "Rendering thumbnails…") else { return }
        let project = snapshot
        Task {
            defer { end("thumbnail") }
            do {
                let folder = project.url.appendingPathComponent("thumbnails", isDirectory: true)
                for format in ThumbnailMaker.Format.allCases {
                    let image = try await ThumbnailMaker.compose(project: project, at: time, headline: headline, kit: kit,
                                                                 faceCutout: faceCutout, format: format)
                    try ThumbnailMaker.savePNG(image, to: folder.appendingPathComponent("thumbnail-\(format.rawValue).png"))
                }
                lastOutputFolder = folder
                NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("thumbnail-youtube.png")])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Guide

    func buildGuide() {
        guard begin("guide", "Building your step-by-step guide…") else { return }
        let placements = self.placements
        let kit = brandKits.first { settings.customGradient == $0.gradient }
        Task {
            defer { end("guide") }
            do {
                try? await ensureWords()
                let folder = try await GuideMaker.build(placements: placements, lines: transcriptLines(), name: name,
                                                       language: captionLanguage, kit: kit, into: project.url) { [weak self] p in
                    Task { @MainActor in self?.report("guide", progress: p) }
                }
                lastOutputFolder = folder
                analysisStatus = "Guide saved: HTML, Markdown and PDF."
                NSWorkspace.shared.open(folder.appendingPathComponent("index.html"))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
