import Foundation

/// Auto mode: when the Mac is red because of memory, pause the heaviest Claude Code session; keep pausing
/// one more every `actionSpacing` while it stays red; once memory has been calm for a minute, resume them
/// one at a time, most recently paused first. A full disk alone never triggers it, pausing cannot help that.
final class AutoPilot {
    enum Decision {
        case pause(SessionRow)
        case resume(SessionRow)
    }

    static let defaultsKey = "autoMode"
    static let memoryRedKeys: Set<String> = ["pressure", "swapout", "swapgrowth", "swap", "used"]
    static let pausedKey = "autoPaused"
    static let shellsKey = "autoPausedShells"
    static let manualKey = "manualPaused"
    static let bootKey = "savedBootTime"

    /// Memory is still busy while a memory reason is red, or the Mac is actively swapping or growing swap.
    /// A kernel "warning" alone is not busy: on a 16 GB Mac it can last for hours, and sessions must not stay
    /// frozen that long. If resuming tips it back to red, the pause logic simply runs again.
    static func memoryBusy(_ reasons: [Reason]) -> Bool {
        reasons.contains { r in
            (memoryRedKeys.contains(r.key) && r.level == .red) || r.key == "swapout" || r.key == "swapgrowth"
        }
    }

    let redSamplesBeforePause = 2
    let calmSamplesBeforeResume = 6
    /// Just under three readings, so the action lands on the third one rather than the fourth.
    let actionSpacing: TimeInterval = 29
    /// Adoption of stranded sessions happens only in the first readings after launch.
    let adoptionSamples = 3
    private var samplesSeen = 0

    /// Sessions we paused, in pause order. Saved, so a restart still knows to resume them.
    private(set) var pausedByUs: [Int32] = [] {
        didSet { UserDefaults.standard.set(pausedByUs.map(Int.init), forKey: Self.pausedKey) }
    }
    /// The shell frozen alongside each paused session, so it can be freed even if the session dies while paused.
    private(set) var shellOf: [Int32: Int32] = [:] {
        didSet { Self.save(shellOf, key: Self.shellsKey) }
    }
    /// Sessions the user paused from the menu (pid -> shell). Auto mode never resumes these.
    private(set) var manuallyPaused: [Int32: Int32] = [:] {
        didSet { Self.save(manuallyPaused, key: Self.manualKey) }
    }

    private static func save(_ map: [Int32: Int32], key: String) {
        var saved: [String: Int] = [:]
        for (pid, shell) in map { saved[String(pid)] = Int(shell) }
        UserDefaults.standard.set(saved, forKey: key)
        UserDefaults.standard.set(bootTime(), forKey: bootKey)
    }

    private static func load(key: String) -> [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] {
            for (pid, shell) in saved { if let p = Int32(pid) { map[p] = Int32(shell) } }
        }
        return map
    }

    /// Seconds since 1970 when this Mac booted. Pids mean nothing across a reboot.
    static func bootTime() -> Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Double(tv.tv_sec)
    }
    private var redStreak = 0
    private var calmStreak = 0
    private var lastAction = Date.distantPast

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    init() {
        // Anything remembered from before the last reboot refers to pids that no longer mean anything.
        let savedBoot = UserDefaults.standard.object(forKey: Self.bootKey) as? Double ?? -1
        guard abs(savedBoot - Self.bootTime()) < 2 else {
            UserDefaults.standard.removeObject(forKey: Self.pausedKey)
            UserDefaults.standard.removeObject(forKey: Self.shellsKey)
            UserDefaults.standard.removeObject(forKey: Self.manualKey)
            return
        }
        if let saved = UserDefaults.standard.array(forKey: Self.pausedKey) as? [Int] {
            pausedByUs = saved.map(Int32.init)
        }
        shellOf = Self.load(key: Self.shellsKey)
        manuallyPaused = Self.load(key: Self.manualKey)
    }

    /// Forget sessions that ended or that were resumed by hand. Returns the shells of sessions that are gone
    /// altogether: they are still frozen and nobody else will ever free them.
    func reconcile(sessions: [SessionRow]) -> [Int32] {
        samplesSeen += 1
        var orphanedShells: [Int32] = []
        func stillPaused(_ pid: Int32) -> Bool { sessions.contains { $0.pid == pid && $0.paused } }
        func gone(_ pid: Int32) -> Bool { !sessions.contains { $0.pid == pid } }
        pausedByUs = pausedByUs.filter { pid in
            if stillPaused(pid) { return true }
            if gone(pid), let shell = shellOf[pid] { orphanedShells.append(shell) }
            shellOf[pid] = nil
            return false
        }
        for (pid, shell) in manuallyPaused where !stillPaused(pid) {
            if gone(pid) { orphanedShells.append(shell) }
            manuallyPaused[pid] = nil
        }
        return orphanedShells
    }

    /// A session found stopped together with its shell right after launch was paused by an earlier Watchdog
    /// (a Ctrl-Z leaves the shell running; a menu pause is recorded as the user's). Take it over so it is
    /// resumed when memory is calm. Later in the run nothing is adopted: a pause that appears then is the user's.
    func adopt(sessions: [SessionRow]) -> [SessionRow] {
        guard samplesSeen < adoptionSamples else { return [] }
        let stranded = sessions.filter {
            $0.paused && $0.shellPaused && !pausedByUs.contains($0.pid) && manuallyPaused[$0.pid] == nil
        }
        for s in stranded {
            pausedByUs.append(s.pid)
            shellOf[s.pid] = s.shellPid
        }
        return stranded
    }

    func markManual(_ pid: Int32, shell: Int32?) {
        pausedByUs.removeAll { $0 == pid }
        shellOf[pid] = nil
        manuallyPaused[pid] = shell ?? 0
    }

    func decide(sample: Sample, verdict: Verdict, shown: Level, now: Date) -> Decision? {
        guard enabled else {
            redStreak = 0
            calmStreak = 0
            return nil
        }

        let memoryRed = shown == .red && verdict.reasons.contains { $0.level == .red && Self.memoryRedKeys.contains($0.key) }
        let memoryBusy = Self.memoryBusy(verdict.reasons)

        if memoryRed {
            redStreak += 1
            calmStreak = 0
            guard redStreak >= redSamplesBeforePause, now.timeIntervalSince(lastAction) >= actionSpacing else { return nil }
            if let target = sample.sessions.filter({ !$0.paused }).max(by: { $0.treeBytes < $1.treeBytes }) {
                return .pause(target)
            }
            return nil
        }

        redStreak = 0
        if memoryBusy {
            calmStreak = 0
            return nil
        }

        calmStreak += 1
        guard !pausedByUs.isEmpty, calmStreak >= calmSamplesBeforeResume, now.timeIntervalSince(lastAction) >= actionSpacing,
              let pid = pausedByUs.last, let session = sample.sessions.first(where: { $0.pid == pid }) else { return nil }
        return .resume(session)
    }

    func didPause(_ pid: Int32, shell: Int32?, at now: Date) {
        pausedByUs.append(pid)
        shellOf[pid] = shell
        lastAction = now
    }

    func didResume(_ pid: Int32, at now: Date) {
        pausedByUs.removeAll { $0 == pid }
        shellOf[pid] = nil
        lastAction = now
    }

    func forget(_ pid: Int32) {
        pausedByUs.removeAll { $0 == pid }
        shellOf[pid] = nil
        manuallyPaused[pid] = nil
    }
}
