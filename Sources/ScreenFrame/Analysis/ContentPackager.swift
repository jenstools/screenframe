import Foundation

/// Everything to publish a video, written from the transcript: title ideas, YouTube chapters and
/// description, a LinkedIn post and a newsletter snippet in Jens's voice (from the jens-voice
/// skill, when installed), hashtags, plus captions as SRT.
struct ContentPackage: Codable, Equatable {
    struct Chapter: Codable, Equatable {
        var t: Double
        var title: String
    }

    var titles: [String] = []
    var chapters: [Chapter] = []
    var youtube = ""
    var linkedin = ""
    var newsletter = ""
    var hashtags: [String] = []
}

enum ContentPackager {
    static var voiceGuide: String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/jens-voice/SKILL.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return String(text.prefix(14_000))
    }

    static func generate(lines: [Captioner.Word], duration: Double, name: String, language: String) async throws -> ContentPackage {
        let german = language.hasPrefix("de")
        var system = """
        You turn the transcript of a screen recording into a publishing package. Write in \(german ? "German" : "English"). \
        Answer with ONLY JSON:
        {"titles": ["3 title ideas, max 60 chars"], "chapters": [{"t": seconds, "title": "..."}],
         "youtube": "description, 2 short paragraphs, then the chapter list as 0:00 Title lines",
         "linkedin": "LinkedIn post (hook in line 1, short lines, no hashtags inside the text)",
         "newsletter": "2–4 sentence newsletter snippet", "hashtags": ["5 hashtags without #"]}
        Chapters: 3–8, the first at 0, only where the topic changes. Never invent facts that aren't in the transcript.
        """
        if let guide = voiceGuide {
            system += "\n\nWrite the LinkedIn post and newsletter snippet in this author's voice. Style guide:\n" + guide
        }
        let prompt = "Video: \(name)\nDuration: \(Int(duration)) s\nTranscript:\n"
            + lines.map { String(format: "[%.1f] %@", $0.start, $0.text) }.joined(separator: "\n")
        let answer = try await AIClient.ask(system: system, prompt: prompt)
        let json = try AIClient.json(in: answer)
        let data = try JSONSerialization.data(withJSONObject: json)
        var package = (try? JSONDecoder().decode(ContentPackage.self, from: data)) ?? ContentPackage()
        package.chapters = package.chapters.filter { $0.t >= 0 && $0.t <= duration }.sorted { $0.t < $1.t }
        if let first = package.chapters.first, first.t > 0 { package.chapters[0].t = 0 }
        return package
    }

    static func srt(from lines: [Captioner.Word]) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return lines.enumerated().map { "\($0.offset + 1)\n\(stamp($0.element.start)) --> \(stamp($0.element.end))\n\($0.element.text)\n" }
            .joined(separator: "\n")
    }

    static func markdown(_ p: ContentPackage, name: String) -> String {
        var md = "# \(name)\n\n## Title ideas\n" + p.titles.map { "- \($0)" }.joined(separator: "\n")
        md += "\n\n## Chapters\n" + p.chapters.map { "\(formatDuration($0.t)) \($0.title)" }.joined(separator: "\n")
        md += "\n\n## YouTube description\n\(p.youtube)\n\n## LinkedIn post\n\(p.linkedin)\n\n## Newsletter\n\(p.newsletter)"
        md += "\n\n## Hashtags\n" + p.hashtags.map { "#\($0)" }.joined(separator: " ") + "\n"
        return md
    }

    /// Writes content.md, chapters.txt and captions.srt into <project>/content and returns the folder.
    static func save(_ p: ContentPackage, captions: [Captioner.Word], name: String, in project: URL) throws -> URL {
        let folder = project.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try markdown(p, name: name).write(to: folder.appendingPathComponent("content.md"), atomically: true, encoding: .utf8)
        try p.chapters.map { "\(formatDuration($0.t)) \($0.title)" }.joined(separator: "\n")
            .write(to: folder.appendingPathComponent("chapters.txt"), atomically: true, encoding: .utf8)
        if !captions.isEmpty {
            try srt(from: captions).write(to: folder.appendingPathComponent("captions.srt"), atomically: true, encoding: .utf8)
        }
        return folder
    }
}
