import Foundation

/// Talks to Claude through the Claude Code CLI already installed on this Mac (print mode, no
/// tools, no MCP servers), so it uses whatever account and provider Claude Code is set up with
/// (here: Bedrock) and needs no extra API key.
enum AIClient {
    enum AIError: LocalizedError {
        case noClaude
        case failed(String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .noClaude: return "Claude Code isn't installed. Install it (or the Claude desktop app) to use the AI features."
            case .failed(let message): return "Claude couldn't answer: \(message)"
            case .badResponse(let text): return "Claude's answer couldn't be read: \(text.prefix(200))"
            }
        }
    }

    /// The newest Claude Code binary: the one bundled with the Claude desktop app, else the CLI.
    static func claudePath() -> String? {
        let fm = FileManager.default
        let bundled = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: bundled.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            let dir = bundled.appendingPathComponent(version)
            for hash in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let path = dir.appendingPathComponent(hash).appendingPathComponent("claude.app/Contents/MacOS/claude").path
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first(where: fm.isExecutableFile)
    }

    /// One question, one answer (the `result` text).
    static func ask(system: String, prompt: String, timeout: TimeInterval = 240) async throws -> String {
        guard let path = claudePath() else { throw AIError.noClaude }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-p", "--output-format", "json", "--tools", "", "--strict-mcp-config",
                                 "--no-session-persistence", "--system-prompt", system]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            environment["PATH"] = (environment["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
            process.environment = environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            input.fileHandleForWriting.write(prompt.data(using: .utf8)!)
            try? input.fileHandleForWriting.close()

            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw AIError.failed(stderr.isEmpty ? "no output" : String(stderr.prefix(300)))
            }
            let result = envelope["result"] as? String ?? ""
            if envelope["is_error"] as? Bool == true { throw AIError.failed(result) }
            return result
        }.value
    }

    /// The first JSON object in a reply (tolerates code fences and prose around it).
    static func json(in text: String) throws -> [String: Any] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse(text)
        }
        return object
    }
}
