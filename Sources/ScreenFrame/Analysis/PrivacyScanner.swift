import AVFoundation
import NaturalLanguage
import Vision

/// Finds sensitive things in a screen recording (on-device): text read with Vision and matched
/// against emails, phone numbers, keys/tokens and personal names, plus faces. Each finding becomes
/// a blur region that lasts as long as it stays on screen.
enum PrivacyScanner {
    private static let email = try! NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive)
    private static let secrets = try! NSRegularExpression(pattern: [
        #"sk-[A-Za-z0-9_\-]{16,}"#, #"AKIA[0-9A-Z]{16}"#, #"gh[pousr]_[A-Za-z0-9]{30,}"#, #"xox[abpr]-[A-Za-z0-9-]{10,}"#,
        #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, #"[A-Za-z0-9_\-]{36,}"#,
        #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}\b"#,
    ].joined(separator: "|"))
    private static let phones = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    struct Finding {
        let kind: BlurRegion.Kind
        let rect: CGRect   // normalized, top-left origin
        let label: String
    }

    /// Scans one clip's media at one frame per second (repeated frames reuse the last result).
    static func scan(media: ClipMedia, source: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [BlurRegion] {
        let asset = AVURLAsset(url: media.videoURL)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 2560, height: 2560)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)

        var regions: [BlurRegion] = []
        var lastSignature: [UInt8] = []
        var lastFindings: [Finding] = []
        var t = 0.0
        while t < duration {
            try Task.checkCancellation()
            if let frame = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let signature = thumbnailSignature(frame)
                let findings: [Finding]
                if !lastSignature.isEmpty, difference(signature, lastSignature) < 2 {
                    findings = lastFindings
                } else {
                    findings = analyze(frame)
                }
                lastSignature = signature
                lastFindings = findings
                for finding in findings { merge(finding, at: t, into: &regions, source: source) }
            }
            t += 1
            progress(min(1, t / duration))
        }
        return regions.map { var r = $0; r.end = min(duration, r.end); r.start = max(0, r.start); return r }
    }

    private static func analyze(_ frame: CGImage) -> [Finding] {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.recognitionLanguages = ["de-DE", "en-US"]
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: frame).perform([text, faces])

        var findings: [Finding] = []
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            let ns = string as NSString
            func add(_ kind: BlurRegion.Kind, _ range: NSRange) {
                guard let swiftRange = Range(range, in: string),
                      let box = try? candidate.boundingBox(for: swiftRange)?.boundingBox else { return }
                findings.append(Finding(kind: kind, rect: topLeft(box), label: ns.substring(with: range)))
            }
            let all = NSRange(location: 0, length: ns.length)
            email.matches(in: string, range: all).forEach { add(.email, $0.range) }
            phones.matches(in: string, range: all).forEach { add(.phone, $0.range) }
            secrets.matches(in: string, range: all).forEach { match in
                let token = ns.substring(with: match.range)
                // Long plain words or numbers aren't secrets; tokens mix letters and digits.
                guard token.rangeOfCharacter(from: .decimalDigits) != nil, token.rangeOfCharacter(from: .letters) != nil else { return }
                add(.secret, match.range)
            }
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = string
            tagger.enumerateTags(in: string.startIndex..<string.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                if tag == .personalName, looksLikePersonName(String(string[range])) { add(.name, NSRange(range, in: string)) }
                return true
            }
        }
        for face in faces.results ?? [] {
            findings.append(Finding(kind: .face, rect: topLeft(face.boundingBox.insetBy(dx: -face.boundingBox.width * 0.2,
                                                                                       dy: -face.boundingBox.height * 0.2)),
                                    label: "Face"))
        }
        return findings
    }

    /// Interface text is full of capitalised words the tagger takes for names ("Gruppe", "Suchen").
    /// A name here needs a first and last name, both capitalised words that aren't common UI terms.
    private static func looksLikePersonName(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).map(String.init)
        guard (2...4).contains(parts.count) else { return false }
        for part in parts {
            guard let first = part.first, first.isUppercase, part.count >= 2,
                  part.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." }),
                  part != part.uppercased(), !uiWords.contains(part.lowercased()) else { return false }
        }
        return true
    }

    private static let uiWords: Set<String> = [
        "neu", "suchen", "alle", "gruppe", "gruppen", "projekt", "projekte", "ordner", "datei", "bearbeiten", "ansicht", "hilfe",
        "teilen", "senden", "start", "startseite", "kontakte", "kontakt", "einstellungen", "nachrichten", "mitteilungen", "jobs",
        "netzwerk", "marketing", "kampagne", "kampagnen", "freitag", "montag", "dienstag", "mittwoch", "donnerstag", "samstag",
        "sonntag", "heute", "gestern", "morgen", "bau", "zukunft", "klicks", "öffnungen", "empfänger", "antworten", "anzeigen",
        "weiter", "zurück", "fenster", "verlauf", "lesezeichen", "profile", "tab", "file", "edit", "view", "window", "help", "new",
        "search", "home", "settings", "share", "send", "open", "save", "close", "team", "teams", "dashboard", "inbox", "today",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "code", "html", "report", "update",
    ]

    /// Extends a region that is still on screen at the same spot, or starts a new one.
    private static func merge(_ finding: Finding, at t: Double, into regions: inout [BlurRegion], source: String) {
        let padded = finding.rect.insetBy(dx: -finding.rect.width * 0.08 - 0.003, dy: -finding.rect.height * 0.25 - 0.003)
        if let i = regions.lastIndex(where: { $0.kind == finding.kind && $0.end >= t - 1.6
                && iou(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h), padded) > 0.4 }) {
            regions[i].end = t + 0.6
            return
        }
        regions.append(BlurRegion(source: source, kind: finding.kind, start: t - 0.5, end: t + 0.6,
                                  x: padded.minX, y: padded.minY, w: padded.width, h: padded.height, label: finding.label))
    }

    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    /// 32×18 grayscale thumbnail, to skip OCR on frames that didn't change.
    private static func thumbnailSignature(_ image: CGImage) -> [UInt8] {
        let w = 32, h = 18
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }

    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }
}
