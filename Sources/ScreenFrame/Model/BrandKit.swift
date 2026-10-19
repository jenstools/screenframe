import AppKit

/// Reusable look for every project: background gradient, fonts, colours, logo, lower third,
/// intro and outro. Stored app-wide in Application Support/ScreenFrame/brandkits.json.
struct BrandKit: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var gradient: [UInt32]
    /// Font family for titles (e.g. "Poppins").
    var font: String
    var textColor: UInt32
    var accentColor: UInt32
    /// Absolute path of the logo (copied into Application Support).
    var logoPath: String?
    var logoCorner = CameraCorner.topRight
    var logoSize = 0.06
    var lowerThirdName = ""
    var lowerThirdTitle = ""
    var introText = ""
    var outroText = ""

    /// A semibold weight of the brand font, if installed.
    var fontPostScriptName: String {
        let manager = NSFontManager.shared
        if let members = manager.availableMembers(ofFontFamily: font) {
            for weight in ["SemiBold", "Semibold", "Bold", "Medium", "Regular"] {
                if let match = members.first(where: { ($0[1] as? String) == weight }), let name = match[0] as? String { return name }
            }
            if let name = members.first?[0] as? String { return name }
        }
        return font
    }
}

enum BrandKitStore {
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenFrame", isDirectory: true)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("logos"), withIntermediateDirectories: true)
        return url
    }

    private static var file: URL { folder.appendingPathComponent("brandkits.json") }

    static func load() -> [BrandKit] {
        if let data = try? Data(contentsOf: file), let kits = try? JSONDecoder().decode([BrandKit].self, from: data), !kits.isEmpty {
            return kits
        }
        let kits = [defaultKit()]
        save(kits)
        return kits
    }

    static func save(_ kits: [BrandKit]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(kits).write(to: file, options: .atomic)
    }

    /// Copies a logo into Application Support so the kit keeps working if the original moves.
    static func importLogo(_ url: URL) -> String? {
        let destination = folder.appendingPathComponent("logos").appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
        return (try? FileManager.default.copyItem(at: url, to: destination)) != nil ? destination.path : nil
    }

    /// snipKI corporate design: signature gradient, Poppins, mint/teal, the white wordmark.
    static func defaultKit() -> BrandKit {
        let skillLogo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/snipki-design/assets/logos/snipki_wordmark_white.png")
        let logo = FileManager.default.fileExists(atPath: skillLogo.path) ? importLogo(skillLogo) : nil
        return BrandKit(name: "snipKI", gradient: [0x1AA47B, 0xFCB55F], font: "Poppins", textColor: 0xFFFFFF,
                        accentColor: 0x07302B, logoPath: logo, lowerThirdName: "Jens Polomski",
                        lowerThirdTitle: "Co-Founder & CEO, snipKI", introText: "", outroText: "snipki.de")
    }
}
