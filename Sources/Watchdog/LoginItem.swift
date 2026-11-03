import Foundation

/// Starts the app at login through a LaunchAgent, the same way ClaudeCoordinator and Battery Guardian start.
/// KeepAlive brings it back if it ever dies.
enum LoginItem {
    static let label = "com.geetpurwar.watchdog"
    static let installedExecutable = "/Applications/Watchdog.app/Contents/MacOS/Watchdog"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var domain: String { "gui/\(getuid())" }

    /// Is this process the one launchd runs for our label? Decide once at launch; it spawns launchctl.
    static func detectManaged() -> Bool {
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label { return true }
        return launchdPid() == getpid()
    }

    /// The pid launchd thinks it is running for this label, if any.
    static func launchdPid() -> Int32? {
        let out = launchctl(["print", "\(domain)/\(label)"])
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = "), let v = Int32(t.dropFirst(6)) { return v }
        }
        return nil
    }

    /// Returns an error message, or nil when written.
    static func writePlist(executable: String = installedExecutable) -> String? {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/watchdog.log",
            "StandardErrorPath": "/tmp/watchdog.err",
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL)
            return nil
        } catch {
            return "could not write \(plistURL.path): \(error)"
        }
    }

    static func removePlist() {
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Write the plist and (re)start the job under launchd.
    @discardableResult
    static func enable(executable: String = installedExecutable) -> String {
        if let error = writePlist(executable: executable) { return error }
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        return launchctl(["bootstrap", domain, plistURL.path])
    }

    @discardableResult
    static func disable() -> String {
        let out = launchctl(["bootout", "\(domain)/\(label)"])
        removePlist()
        return out
    }

    /// Stop the running job now. The plist stays, so it comes back at the next login.
    static func stopNow() {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "launchctl failed: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
