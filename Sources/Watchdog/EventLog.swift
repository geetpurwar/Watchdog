import Foundation
import Darwin

/// Writes every reading to disk, so the last minutes before a freeze survive a forced power-off.
/// All writes happen on a private queue; while the colour is orange or red each row is forced to the
/// flash with F_FULLFSYNC, otherwise the kernel flushes in its own time.
final class EventLog {
    let directory: URL
    let samplesURL: URL
    let eventsURL: URL
    private let queue = DispatchQueue(label: "watchdog.log", qos: .utility)
    private let rotateAt: UInt64 = 20 * 1024 * 1024
    private let header = "time,level,pressure,used_gb,compressed_gb,swap_gb,swapout_mbps,swap_growth_2m_gb,disk_free_gb,disk_free_pct,disk_write_mbps,disk_write_ms,load1,claude_sessions,claude_gb,top_process,top_gb\n"
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    init() {
        let env = ProcessInfo.processInfo.environment
        let logs: URL
        if let custom = env["WATCHDOG_LOG_DIR"], !custom.isEmpty {
            logs = URL(fileURLWithPath: custom)
        } else if Bundle.main.bundleIdentifier == nil {
            // A raw binary (tests) must not mix its rows into the real log.
            logs = FileManager.default.temporaryDirectory.appendingPathComponent("WatchdogDev")
        } else {
            logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Watchdog")
        }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        directory = logs
        samplesURL = logs.appendingPathComponent("samples.csv")
        eventsURL = logs.appendingPathComponent("events.log")
        // A file from an older version with a different header is set aside, so columns always match.
        if let existing = try? String(contentsOf: samplesURL, encoding: .utf8).split(separator: "\n", maxSplits: 1).first,
           existing + "\n" != header {
            let old = samplesURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: samplesURL, to: old)
        }
        if !FileManager.default.fileExists(atPath: samplesURL.path) {
            append(header, to: samplesURL, fullSync: false)
        }
    }

    func sample(_ s: Sample, level: Level) {
        let top = s.topProcesses.first
        let line = [
            formatter.string(from: s.date),
            level.name,
            String(s.pressureLevel),
            String(format: "%.2f", Format.gbValue(s.usedBytes)),
            String(format: "%.2f", Format.gbValue(s.compressedBytes)),
            String(format: "%.2f", Format.gbValue(s.swapUsedBytes)),
            String(format: "%.1f", s.swapOutBytesPerSec / 1_048_576),
            String(format: "%.2f", Format.gbValue(s.swapGrowth2mBytes)),
            String(format: "%.1f", Format.gbValue(s.diskFreeBytes)),
            String(format: "%.1f", s.diskFreePercent),
            String(format: "%.1f", s.diskWriteBytesPerSec / 1_048_576),
            String(format: "%.1f", s.diskWriteLatencyMs),
            String(format: "%.1f", s.load1),
            String(s.claudeCount),
            String(format: "%.2f", Format.gbValue(s.claudeBytes)),
            (top?.name ?? "").replacingOccurrences(of: ",", with: " "),
            String(format: "%.2f", Format.gbValue(top?.footprintBytes ?? 0)),
        ].joined(separator: ",") + "\n"
        queue.async { [self] in append(line, to: samplesURL, fullSync: level != .green) }
    }

    func event(_ text: String) {
        let line = "\(formatter.string(from: Date())) \(text)\n"
        queue.async { [self] in append(line, to: eventsURL, fullSync: true) }
    }

    /// Wait for everything queued so far to reach the file. Used right before exit.
    func flush() {
        queue.sync {}
    }

    private func append(_ text: String, to url: URL, fullSync: Bool) {
        if rotateIfNeeded(url), url == samplesURL {
            write(header, to: url, fullSync: false)
        }
        write(text, to: url, fullSync: fullSync)
    }

    private func write(_ text: String, to url: URL, fullSync: Bool) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        text.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
        if fullSync {
            _ = fcntl(fd, F_FULLFSYNC)
        }
    }

    /// Returns true when the file was rotated away.
    private func rotateIfNeeded(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > rotateAt else { return false }
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        return true
    }
}
