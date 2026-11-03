import Foundation

enum Level: Int, Codable, Comparable {
    case green = 0, orange = 1, red = 2

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .green: return "OK"
        case .orange: return "Warning"
        case .red: return "Danger"
        }
    }
    var name: String {
        switch self {
        case .green: return "green"
        case .orange: return "orange"
        case .red: return "red"
        }
    }
}

/// Limits that decide the colour. Override any of them with
/// `defaults write com.geetpurwar.watchdog <key> <value>` and restart the app.
struct Thresholds {
    var swapOrangeGB = 4.0
    var swapRedGB = 8.0
    /// Sustained swap-out speed, averaged over 30 s.
    var swapOutOrangeMBps = 20.0
    var swapOutRedMBps = 100.0
    /// Swap growth over two minutes.
    var swapGrowthRedGB = 1.0
    var diskOrangeGB = 15.0
    var diskRedGB = 6.0
    var diskOrangePercent = 5.0
    var diskRedPercent = 1.5
    var usedOrangePercent = 93.0
    /// 0 = off. Load alone does not freeze this Mac; memory and disk do.
    var loadOrangePerCore = 0.0

    static let suite = "com.geetpurwar.watchdog"

    static func load() -> Thresholds {
        var t = Thresholds()
        // Inside the app bundle the suite is our own domain, and UserDefaults(suiteName:) refuses that.
        let d: UserDefaults
        if Bundle.main.bundleIdentifier == suite {
            d = UserDefaults.standard
        } else if let s = UserDefaults(suiteName: suite) {
            d = s
        } else {
            return t
        }
        func pick(_ key: String, _ into: inout Double) {
            if let v = d.object(forKey: key) as? NSNumber { into = v.doubleValue }
        }
        pick("swapOrangeGB", &t.swapOrangeGB)
        pick("swapRedGB", &t.swapRedGB)
        pick("swapOutOrangeMBps", &t.swapOutOrangeMBps)
        pick("swapOutRedMBps", &t.swapOutRedMBps)
        pick("swapGrowthRedGB", &t.swapGrowthRedGB)
        pick("diskOrangeGB", &t.diskOrangeGB)
        pick("diskRedGB", &t.diskRedGB)
        pick("diskOrangePercent", &t.diskOrangePercent)
        pick("diskRedPercent", &t.diskRedPercent)
        pick("usedOrangePercent", &t.usedOrangePercent)
        pick("loadOrangePerCore", &t.loadOrangePerCore)
        return t
    }
}

/// One thing that is wrong. `key` is stable across readings; `text` carries the numbers.
struct Reason {
    let key: String
    let level: Level
    let text: String
}

struct Verdict {
    let level: Level
    let reasons: [Reason]
    var texts: [String] { reasons.map(\.text) }
}

enum Rules {
    static func evaluate(_ s: Sample, thresholds t: Thresholds) -> Verdict {
        var red: [Reason] = []
        var orange: [Reason] = []
        func flag(_ key: String, _ level: Level, _ text: String) {
            if level == .red { red.append(Reason(key: key, level: .red, text: text)) }
            else { orange.append(Reason(key: key, level: .orange, text: text)) }
        }

        // The kernel's own view. 3 (urgent) and 4 (critical) both mean it is already killing or about to.
        if s.pressureLevel >= 3 {
            flag("pressure", .red, "Memory pressure is critical. The Mac is out of RAM.")
        } else if s.pressureLevel == 2 {
            flag("pressure", .orange, "Memory pressure warning. RAM is nearly full.")
        }

        // How fast memory is being pushed to disk. This is what a freeze looks like a few minutes early.
        let swapOutMB = s.swapOutBytesPerSec / 1_048_576
        if swapOutMB >= t.swapOutRedMBps {
            flag("swapout", .red, "Swapping hard: \(Format.mbps(s.swapOutBytesPerSec)) to disk.")
        } else if swapOutMB >= t.swapOutOrangeMBps {
            flag("swapout", .orange, "Swapping: \(Format.mbps(s.swapOutBytesPerSec)) to disk.")
        }
        if Format.gbValue(s.swapGrowth2mBytes) >= t.swapGrowthRedGB {
            flag("swapgrowth", .red, "Swap grew by \(Format.gb(s.swapGrowth2mBytes)) in two minutes.")
        }

        let swap = Format.gbValue(s.swapUsedBytes)
        if swap >= t.swapRedGB {
            flag("swap", .red, "Swap is \(Format.gb(s.swapUsedBytes)). The disk is being used as RAM.")
        } else if swap >= t.swapOrangeGB {
            flag("swap", .orange, "Swap is \(Format.gb(s.swapUsedBytes)).")
        }

        // A nearly full SSD slows every write, and swap has nowhere to go. Judge by percent and by GB.
        let diskGB = Format.gbValue(s.diskFreeBytes)
        let diskPct = s.diskFreePercent
        let diskText = "\(Format.gb(s.diskFreeBytes, decimals: 0)) free (\(String(format: "%.1f", diskPct))%)"
        if diskGB < t.diskRedGB || diskPct < t.diskRedPercent {
            flag("disk", .red, "Disk almost full: \(diskText). Swap has no room.")
        } else if diskGB < t.diskOrangeGB || diskPct < t.diskOrangePercent {
            flag("disk", .orange, "Disk is getting full: \(diskText).")
        }

        let usedPercent = s.totalBytes > 0 ? Double(s.usedBytes) / Double(s.totalBytes) * 100 : 0
        if usedPercent >= t.usedOrangePercent {
            flag("used", .orange, "Memory used is \(Int(usedPercent))%.")
        }

        if t.loadOrangePerCore > 0, s.load1 >= Double(s.cpuCount) * t.loadOrangePerCore {
            flag("load", .orange, "Load is \(Int(s.load1)) on \(s.cpuCount) cores.")
        }

        if !red.isEmpty { return Verdict(level: .red, reasons: red + orange) }
        if !orange.isEmpty { return Verdict(level: .orange, reasons: orange) }
        return Verdict(level: .green, reasons: [])
    }
}

/// What `--status` prints.
struct StatusReport: Codable {
    let level: String
    let reasons: [String]
    let pressureLevel: Int
    let memoryUsedGB: Double
    let memoryTotalGB: Double
    let compressedGB: Double
    let swapUsedGB: Double
    let swapOutMBps: Double
    let swapGrowth2mGB: Double
    let diskFreeGB: Double
    let diskFreePercent: Double
    let diskFreeFinderGB: Double
    let diskWriteMBps: Double
    let diskWriteLatencyMs: Double
    let load1: Double
    let cpuCount: Int
    let claudeSessions: Int
    let claudeGB: Double
    let sessions: [SessionRow]
    let topProcesses: [ProcessRow]

    init(sample s: Sample, verdict v: Verdict) {
        func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        level = v.level.name
        reasons = v.texts
        pressureLevel = s.pressureLevel
        memoryUsedGB = r1(Format.gbValue(s.usedBytes))
        memoryTotalGB = Format.gbValue(s.totalBytes)
        compressedGB = r1(Format.gbValue(s.compressedBytes))
        swapUsedGB = r1(Format.gbValue(s.swapUsedBytes))
        swapOutMBps = r1(s.swapOutBytesPerSec / 1_048_576)
        swapGrowth2mGB = r1(Format.gbValue(s.swapGrowth2mBytes))
        diskFreeGB = r1(Format.gbValue(s.diskFreeBytes))
        diskFreePercent = r1(s.diskFreePercent)
        diskFreeFinderGB = r1(Format.gbValue(s.diskFreeImportantBytes))
        diskWriteMBps = r1(s.diskWriteBytesPerSec / 1_048_576)
        diskWriteLatencyMs = r1(s.diskWriteLatencyMs)
        load1 = r1(s.load1)
        cpuCount = s.cpuCount
        claudeSessions = s.claudeCount
        claudeGB = r1(Format.gbValue(s.claudeBytes))
        sessions = s.sessions
        topProcesses = s.topProcesses
    }
}
