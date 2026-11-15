import Foundation

/// A short made from a longer video, plus what gets posted with it.
///
/// Stored as `social.json` in the short's own project folder, next to (not inside) project.json:
/// the short's editor saves project.json wholesale, so keeping the post text apart lets both the
/// short's window and the original's Social tab edit it without overwriting each other.
struct ShortInfo: Codable, Equatable {
    /// Project folder of the video it was cut from.
    var parentPath: String
    var parentName: String
    /// Position among the original's shorts (1-based), for ordering and file names.
    var index: Int
    /// YouTube title (max 100 characters).
    var title: String
    var description: String
    /// Without "#".
    var hashtags: [String]
    /// The original's timeline stretches it was cut from.
    var ranges: [SourceRange]
    var createdAt = Date()
    /// On-screen hook title, kept so it comes back when the hook is switched off and on again.
    var hook: String?
    /// Name of the style it was given (for display; the look itself lives in the project).
    var styleName: String?
    /// The last exported file.
    var exportedPath: String?
    var exportedAt: Date?

    struct SourceRange: Codable, Equatable {
        var start: Double
        var end: Double
    }

    static let titleLimit = 100
    static let descriptionLimit = 5000

    var parentURL: URL { URL(fileURLWithPath: parentPath, isDirectory: true) }

    /// "#a #b #c", with #Shorts first.
    var hashtagLine: String {
        var tags = hashtags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.filter { !$0.isEmpty }
        if !tags.contains(where: { $0.caseInsensitiveCompare("Shorts") == .orderedSame }) { tags.insert("Shorts", at: 0) }
        return tags.map { "#\($0)" }.joined(separator: " ")
    }

    /// Everything to paste into YouTube Studio.
    var postText: String {
        "\(title)\n\n\(description)\n\n\(hashtagLine)\n"
    }

    /// Parses "#a, b #c" into ["a", "b", "c"].
    static func parseHashtags(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
    }
}

/// A short of the open video, as listed in its Social tab.
struct ShortEntry: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    var info: ShortInfo
    var duration: Double
}

enum ShortStore {
    static let fileName = "social.json"
    /// Posted when a short's info is saved, with the short's folder as object, so other windows refresh.
    static let changed = Notification.Name("ScreenFrameShortChanged")

    static func load(_ folder: URL) -> ShortInfo? {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? ProjectStore.read(ShortInfo.self, from: url)
    }

    static func save(_ info: ShortInfo, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: folder.appendingPathComponent(fileName), options: .atomic)
        NotificationCenter.default.post(name: changed, object: folder)
    }

    static func isShort(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path)
    }

    /// Every short cut from `parent`, in order.
    static func shorts(of parent: URL) -> [ShortEntry] {
        let fm = FileManager.default
        let parentPath = parent.standardizedFileURL.path
        guard let items = try? fm.contentsOfDirectory(at: ProjectStore.root, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { url -> ShortEntry? in
            guard let info = load(url), URL(fileURLWithPath: info.parentPath).standardizedFileURL.path == parentPath,
                  let project = try? ProjectStore.load(url) else { return nil }
            return ShortEntry(url: url, info: info, duration: project.totalDuration)
        }
        .sorted { ($0.info.index, $0.info.createdAt) < ($1.info.index, $1.info.createdAt) }
    }

    /// ~/Movies/<original> – Shorts
    static func exportFolder(parentName: String) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("\(safeName(parentName)) – Shorts", isDirectory: true)
    }

    /// "03 Title of the short" (no extension), cut at a word boundary.
    static func exportBaseName(_ info: ShortInfo) -> String {
        var title = safeName(info.title)
        if title.count > 60 {
            let cut = title.prefix(60)
            title = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]).trimmingCharacters(in: CharacterSet(charactersIn: " -–,."))
        }
        return String(format: "%02d ", info.index) + title
    }

    /// Usable as a file name: ":" becomes " -", other reserved characters go, spaces collapse.
    static func safeName(_ name: String) -> String {
        var text = name.replacingOccurrences(of: ":", with: " -")
        text = text.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>\n\r\t")).joined(separator: " ")
        let cleaned = text.split(separator: " ").joined(separator: " ")
        return cleaned.isEmpty ? "Short" : cleaned
    }
}
