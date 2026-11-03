import Foundation
import Darwin
import IOKit

/// One running process, as seen by the watchdog.
struct ProcessRow: Codable {
    let pid: Int32
    let name: String
    let footprintBytes: UInt64
    let ownedByMe: Bool
    let paused: Bool
    let parentPid: Int32
    let tty: String
    let startedAt: Date
}

/// One Claude Code session: the `claude` process plus everything it spawned.
struct SessionRow: Codable {
    let pid: Int32
    /// Last folder of its working directory, so the user knows which one it is.
    let label: String
    let cwd: String
    /// The interactive shell that started it, if any. Frozen together with the session so it cannot grab the terminal.
    let shellPid: Int32?
    let treeBytes: UInt64
    let treeCount: Int
    let paused: Bool
    /// Terminal it runs in, e.g. "ttys009", or "" when it has none.
    let tty: String
    let startedAt: Date
}

/// One reading of the machine. Everything the rules and the menu need.
struct Sample: Codable {
    let date: Date
    /// Kernel memory pressure: 1 normal, 2 warning, 3 urgent, 4 critical.
    let pressureLevel: Int
    let totalBytes: UInt64
    /// App memory + wired + compressed. Same number Activity Monitor calls "Memory Used".
    let usedBytes: UInt64
    let compressedBytes: UInt64
    let freeBytes: UInt64
    let swapUsedBytes: UInt64
    /// Bytes per second being written out to swap, averaged over the last three readings.
    let swapOutBytesPerSec: Double
    /// How much swap grew over the last two minutes (0 if it shrank).
    let swapGrowth2mBytes: UInt64
    let diskFreeBytes: UInt64
    /// Free space counting purgeable files, the number Finder shows.
    let diskFreeImportantBytes: UInt64
    let diskTotalBytes: UInt64
    let diskWriteBytesPerSec: Double
    let diskWriteLatencyMs: Double
    let load1: Double
    let load5: Double
    let cpuCount: Int
    let sessions: [SessionRow]
    let topProcesses: [ProcessRow]

    var claudeCount: Int { sessions.count }
    var claudeBytes: UInt64 { sessions.reduce(0) { $0 + $1.treeBytes } }
    var diskFreePercent: Double {
        diskTotalBytes > 0 ? Double(diskFreeBytes) / Double(diskTotalBytes) * 100 : 0
    }
}

/// Remembers the previous readings so rates can be worked out. Use from one queue only.
final class History {
    struct DiskCounters {
        var bytesWritten: UInt64 = 0
        var writeOps: UInt64 = 0
        var writeTimeNs: UInt64 = 0
    }
    var lastDate: Date?
    var lastSwapouts: UInt64?
    var lastDisk: DiskCounters?
    var swapOutRates: [Double] = []
    var swapUsedRing: [(date: Date, used: UInt64)] = []
}

enum Sampler {
    static let dataVolume = "/System/Volumes/Data"
    static let topLimit = 10
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "login"]
    private static let hostPort: mach_port_t = mach_host_self()
    private static let env = ProcessInfo.processInfo.environment

    static func take(history: History) -> Sample {
        let now = Date()
        let pageSize = UInt64(vm_kernel_page_size)
        let vm = vmStats()
        let total = sysctlUInt64("hw.memsize")
        let compressed = UInt64(vm.compressor_page_count) * pageSize
        let internalPages = UInt64(vm.internal_page_count)
        let purgeable = min(internalPages, UInt64(vm.purgeable_count))
        let used = (internalPages - purgeable + UInt64(vm.wire_count)) * pageSize + compressed
        let free = UInt64(vm.free_count) * pageSize

        let swap = swapUsage()
        let disk = diskSpace(dataVolume)
        let diskImportant = diskFreeForImportantUsage(dataVolume) ?? disk.free
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let cpu = max(1, sysctlInt("hw.ncpu"))

        let pressure = fakePressure() ?? sysctlInt("kern.memorystatus_vm_pressure_level")

        // Rates since the previous reading.
        let elapsed = history.lastDate.map { now.timeIntervalSince($0) } ?? 0
        if let last = history.lastSwapouts, elapsed > 0.5, vm.swapouts >= last {
            history.swapOutRates.append(Double(vm.swapouts - last) * Double(pageSize) / elapsed)
            if history.swapOutRates.count > 3 { history.swapOutRates.removeFirst() }
        }
        let swapOutAverage = history.swapOutRates.isEmpty ? 0 : history.swapOutRates.reduce(0, +) / Double(history.swapOutRates.count)
        history.lastSwapouts = vm.swapouts

        history.swapUsedRing.append((now, swap.xsu_used))
        history.swapUsedRing.removeAll { now.timeIntervalSince($0.date) > 125 }
        let oldestSwap = history.swapUsedRing.first?.used ?? swap.xsu_used
        let swapGrowth = swap.xsu_used > oldestSwap ? swap.xsu_used - oldestSwap : 0

        var writeRate = 0.0
        var writeLatency = 0.0
        let diskNow = diskCounters()
        if let diskNow, let last = history.lastDisk, elapsed > 0.5,
           diskNow.bytesWritten >= last.bytesWritten, diskNow.writeOps >= last.writeOps, diskNow.writeTimeNs >= last.writeTimeNs {
            writeRate = Double(diskNow.bytesWritten - last.bytesWritten) / elapsed
            let ops = diskNow.writeOps - last.writeOps
            if ops > 0 {
                writeLatency = Double(diskNow.writeTimeNs - last.writeTimeNs) / Double(ops) / 1_000_000
            }
        }
        history.lastDisk = diskNow
        history.lastDate = now

        let procs = processes()
        let sessions = sessions(in: procs)

        return Sample(
            date: now,
            pressureLevel: pressure,
            totalBytes: total,
            usedBytes: min(used, total),
            compressedBytes: compressed,
            freeBytes: free,
            swapUsedBytes: swap.xsu_used,
            swapOutBytesPerSec: swapOutAverage,
            swapGrowth2mBytes: swapGrowth,
            diskFreeBytes: disk.free,
            diskFreeImportantBytes: diskImportant,
            diskTotalBytes: disk.total,
            diskWriteBytesPerSec: writeRate,
            diskWriteLatencyMs: writeLatency,
            load1: loads[0],
            load5: loads[1],
            cpuCount: cpu,
            sessions: sessions,
            topProcesses: Array(procs.prefix(topLimit))
        )
    }

    /// Test hook: WATCHDOG_FAKE_PRESSURE=<n>, or WATCHDOG_FAKE_PRESSURE_FILE=<path> read every time.
    private static func fakePressure() -> Int? {
        if let v = env["WATCHDOG_FAKE_PRESSURE"], let n = Int(v) { return n }
        if let path = env["WATCHDOG_FAKE_PRESSURE_FILE"],
           let text = try? String(contentsOfFile: path, encoding: .utf8),
           let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return n
        }
        return nil
    }

    // MARK: - Kernel readings

    static func sysctlUInt64(_ name: String) -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname(name, &value, &size, nil, 0)
        return value
    }

    static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname(name, &value, &size, nil, 0)
        return Int(value)
    }

    static func swapUsage() -> xsw_usage {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return usage
    }

    static func vmStats() -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        return stats
    }

    static func diskSpace(_ path: String) -> (free: UInt64, total: UInt64) {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return (0, 0) }
        let block = UInt64(fs.f_bsize)
        return (UInt64(fs.f_bavail) * block, UInt64(fs.f_blocks) * block)
    }

    static func diskFreeForImportantUsage(_ path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let v = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return UInt64(max(0, v))
    }

    /// Lifetime write counters of every block storage driver, summed. Same source as `iostat`.
    static func diskCounters() -> History.DiskCounters? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var total = History.DiskCounters()
        var found = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let raw = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let stats = raw as? [String: Any] {
                found = true
                total.bytesWritten += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                total.writeOps += (stats["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0
                total.writeTimeNs += (stats["Total Time (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found ? total : nil
    }

    // MARK: - Processes

    /// Claude Code runs from ~/.local/share/claude/versions/<version>, so the kernel names it "2.1.312".
    /// WATCHDOG_SESSION_PATH=<prefix> (tests) makes only executables under that prefix count.
    static func isClaudeExecutable(_ path: String) -> Bool {
        if let prefix = env["WATCHDOG_SESSION_PATH"], !prefix.isEmpty {
            return path.hasPrefix(prefix)
        }
        // The native install, an npm install, or a `claude` on a bin path. A stray binary merely named
        // "claude" somewhere else (a test fixture, a scratch folder) does not count.
        return path.contains("/claude/versions/")
            || path.contains("@anthropic-ai/claude-code")
            || path.hasSuffix("/bin/claude")
    }

    /// Every process we can measure, biggest footprint first.
    static func processes() -> [ProcessRow] {
        let pidSize = MemoryLayout<pid_t>.size
        // proc_listallpids returns a pid count (libproc divides the kernel's byte count by sizeof(int)).
        // Verified on macOS 26.5: 749 with a nil buffer against 733 from `ps -e`.
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * pidSize))
        guard got > 0 else { return [] }
        let count = min(pids.count, Int(got))

        let me = getuid()
        var rows: [ProcessRow] = []
        rows.reserveCapacity(count)
        var nameBuffer = [CChar](repeating: 0, count: 256)
        var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        for pid in pids.prefix(count) where pid > 0 {
            var usage = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0, usage.ri_phys_footprint > 0 else { continue }

            nameBuffer[0] = 0
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            var name = String(cString: nameBuffer)

            pathBuffer[0] = 0
            if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0, isClaudeExecutable(String(cString: pathBuffer)) {
                name = "claude"
            }

            var bsd = proc_bsdinfo()
            let wanted = Int32(MemoryLayout<proc_bsdinfo>.size)
            let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, wanted)
            let haveInfo = n == wanted
            let owned = haveInfo && bsd.pbi_ruid == me
            let paused = haveInfo && bsd.pbi_status == UInt32(SSTOP)
            let parent = haveInfo ? Int32(bsd.pbi_ppid) : 0
            var tty = ""
            if haveInfo, bsd.e_tdev != UInt32.max, let dev = devname(dev_t(bsd.e_tdev), S_IFCHR) {
                tty = String(cString: dev)
            }
            let started = haveInfo ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)) : Date.distantPast

            rows.append(ProcessRow(
                pid: pid,
                name: name.isEmpty ? "pid \(pid)" : name,
                footprintBytes: usage.ri_phys_footprint,
                ownedByMe: owned,
                paused: paused,
                parentPid: parent,
                tty: tty,
                startedAt: started
            ))
        }
        return rows.sorted { $0.footprintBytes > $1.footprintBytes }
    }

    /// Claude Code sessions with their process trees. A `claude -p` child of a session is part of that session, not a session.
    static func sessions(in rows: [ProcessRow]) -> [SessionRow] {
        let byPid = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        var childrenOf: [Int32: [ProcessRow]] = [:]
        for r in rows { childrenOf[r.parentPid, default: []].append(r) }

        let claudePids = Set(rows.filter { $0.name == "claude" }.map(\.pid))
        let roots = rows.filter { $0.name == "claude" && !claudePids.contains($0.parentPid) }

        return roots.map { root in
            var bytes = root.footprintBytes
            var count = 1
            var queue = childrenOf[root.pid] ?? []
            var seen = Set<Int32>([root.pid])
            while let p = queue.popLast() {
                guard !seen.contains(p.pid) else { continue }
                seen.insert(p.pid)
                bytes += p.footprintBytes
                count += 1
                queue.append(contentsOf: childrenOf[p.pid] ?? [])
            }
            let parent = byPid[root.parentPid]
            let shell = parent.flatMap { shells.contains($0.name) ? $0.pid : nil }
            let cwd = workingDirectory(of: root.pid) ?? ""
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let label: String
            if cwd.isEmpty { label = "claude \(root.pid)" }
            else if cwd == home { label = "~" }
            else { label = URL(fileURLWithPath: cwd).lastPathComponent }
            return SessionRow(pid: root.pid, label: label, cwd: cwd, shellPid: shell,
                              treeBytes: bytes, treeCount: count, paused: root.paused,
                              tty: root.tty, startedAt: root.startedAt)
        }.sorted { $0.treeBytes > $1.treeBytes }
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Every process below `pid`, parents before children.
    static func descendants(of pid: pid_t) -> [pid_t] {
        let pidSize = MemoryLayout<pid_t>.size
        var result: [pid_t] = []
        var queue = [pid]
        var seen = Set<pid_t>([pid])
        while let parent = queue.popLast() {
            // Same as proc_listallpids: a pid count, not bytes.
            let needed = proc_listchildpids(parent, nil, 0)
            guard needed > 0 else { continue }
            var buffer = [pid_t](repeating: 0, count: Int(needed) + 16)
            let got = proc_listchildpids(parent, &buffer, Int32(buffer.count * pidSize))
            guard got > 0 else { continue }
            for child in buffer.prefix(min(buffer.count, Int(got))) where child > 0 && !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// The parent shell of a process, if its parent is an interactive shell.
    static func parentShell(of pid: pid_t) -> pid_t? {
        var bsd = proc_bsdinfo()
        let wanted = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, wanted) == wanted else { return nil }
        let parent = pid_t(bsd.pbi_ppid)
        var nameBuffer = [CChar](repeating: 0, count: 256)
        proc_name(parent, &nameBuffer, UInt32(nameBuffer.count))
        return shells.contains(String(cString: nameBuffer)) ? parent : nil
    }
}

/// Freezing and thawing a process tree. The parent shell is stopped first and continued last, so it never
/// notices the stop, never takes the terminal back, and the job carries on in the foreground afterwards.
/// (Verified on zsh: a plain stop makes the resumed job die or re-stop on its next keyboard read.)
enum SessionControl {
    struct Outcome {
        var ok = 0
        var failed = 0
        var description: String { "ok=\(ok) failed=\(failed)" }
    }

    static func pause(pid: pid_t, shell: pid_t?) -> Outcome {
        signal([shell].compactMap { $0 } + [pid] + Sampler.descendants(of: pid), SIGSTOP)
    }

    static func resume(pid: pid_t, shell: pid_t?) -> Outcome {
        signal(Sampler.descendants(of: pid).reversed() + [pid] + [shell].compactMap { $0 }, SIGCONT)
    }

    static func quit(pid: pid_t) -> Outcome {
        signal([pid] + Sampler.descendants(of: pid), SIGTERM)
    }

    private static func signal(_ pids: [pid_t], _ sig: Int32) -> Outcome {
        var o = Outcome()
        for p in pids {
            if kill(p, sig) == 0 { o.ok += 1 } else { o.failed += 1 }
        }
        return o
    }
}

enum Format {
    static func gb(_ bytes: UInt64, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f GB", Double(bytes) / 1_073_741_824)
    }
    static func gbValue(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_073_741_824
    }
    static func mbps(_ bytesPerSec: Double) -> String {
        String(format: "%.0f MB/s", bytesPerSec / 1_048_576)
    }
}
