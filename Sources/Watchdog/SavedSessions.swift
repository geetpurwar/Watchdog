import Foundation

/// A Claude Code session that Watchdog ended and can bring back. The transcript itself is Claude Code's
/// own (~/.claude/projects/…/<id>.jsonl, written as the session runs); this is just how to reopen it.
struct SavedSession: Codable, Equatable {
    let sessionId: String
    let name: String
    let cwd: String
    /// Original command line without the executable, with any earlier `--resume <id>` removed.
    let args: [String]
    let treeBytes: UInt64
    let status: String
    let quitAt: Date
    let reason: String

    var resumeArguments: [String] { ["claude", "--resume", sessionId] + args }
    /// What to type in a shell to bring it back.
    var resumeCommand: String {
        resumeArguments.map(SavedSessionStore.shellQuote).joined(separator: " ")
    }
}

/// Saved sessions on disk, plus the launcher that reopens one in a terminal.
final class SavedSessionStore {
    let fileURL: URL
    private(set) var sessions: [SavedSession] = []

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("saved-sessions.json")
        load()
    }

    static func defaultDirectory(logDirectory: URL) -> URL {
        if Bundle.main.bundleIdentifier == nil { return logDirectory }   // raw test binary: keep it beside its log
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Watchdog")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = (try? decoder.decode([SavedSession].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sessions) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ s: SavedSession) {
        sessions.removeAll { $0.sessionId == s.sessionId }
        sessions.append(s)
        save()
    }

    func remove(sessionId: String) {
        sessions.removeAll { $0.sessionId == sessionId }
        save()
    }

    // MARK: - Reopening

    /// Open a new terminal tab in the session's folder and run its resume command. Ghostty first (the user's
    /// terminal), Terminal.app as a fallback. WATCHDOG_RESUME_DRY_RUN=1 only reports what would run.
    func launch(_ s: SavedSession) -> Result<String, Error> {
        let command = s.resumeCommand
        if ProcessInfo.processInfo.environment["WATCHDOG_RESUME_DRY_RUN"] != nil {
            return .success("dry run: cd \(Self.shellQuote(s.cwd)) && \(command)")
        }
        let ghostty = """
        tell application "Ghostty"
            activate
            try
                new tab in window 1 with configuration {initial working directory:"\(Self.appleScriptQuote(s.cwd))", initial input:("\(Self.appleScriptQuote(command))" & linefeed)}
            on error
                new window with configuration {initial working directory:"\(Self.appleScriptQuote(s.cwd))", initial input:("\(Self.appleScriptQuote(command))" & linefeed)}
            end try
        end tell
        """
        if FileManager.default.fileExists(atPath: "/Applications/Ghostty.app") {
            switch Self.osascript(ghostty) {
            case .success: return .success("opened a Ghostty tab in \(s.cwd)")
            case .failure(let e): NSLogIfNeeded("Ghostty launch failed: \(e)")
            }
        }
        let shell = "cd \(Self.shellQuote(s.cwd)) && \(command)"
        let terminal = """
        tell application "Terminal"
            activate
            do script "\(Self.appleScriptQuote(shell))"
        end tell
        """
        return Self.osascript(terminal).map { _ in "opened a Terminal window in \(s.cwd)" }
    }

    private static func osascript(_ script: String) -> Result<String, Error> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        do { try p.run() } catch { return .failure(error) }
        input.fileHandleForWriting.write(script.data(using: .utf8) ?? Data())
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus == 0 { return .success(text) }
        return .failure(NSError(domain: "osascript", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text.trimmingCharacters(in: .whitespacesAndNewlines)]))
    }

    static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@,+"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private func NSLogIfNeeded(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8) ?? Data())
}
