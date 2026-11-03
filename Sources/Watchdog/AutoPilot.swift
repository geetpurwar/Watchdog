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
    /// Reasons that mean memory is still busy. The static swap level is left out: swap lingers for hours after a crunch.
    static let memoryBusyKeys: Set<String> = ["pressure", "swapout", "swapgrowth", "used"]

    let redSamplesBeforePause = 2
    let calmSamplesBeforeResume = 6
    let actionSpacing: TimeInterval = 30

    private(set) var pausedByUs: [Int32] = []
    private var redStreak = 0
    private var calmStreak = 0
    private var lastAction = Date.distantPast

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    /// Forget sessions that ended or that the user resumed by hand.
    func reconcile(sessions: [SessionRow]) {
        pausedByUs = pausedByUs.filter { pid in sessions.contains { $0.pid == pid && $0.paused } }
    }

    func decide(sample: Sample, verdict: Verdict, shown: Level, now: Date) -> Decision? {
        reconcile(sessions: sample.sessions)
        guard enabled else {
            redStreak = 0
            calmStreak = 0
            return nil
        }

        let memoryRed = shown == .red && verdict.reasons.contains { $0.level == .red && Self.memoryRedKeys.contains($0.key) }
        let memoryBusy = verdict.reasons.contains { Self.memoryBusyKeys.contains($0.key) }

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

    func didPause(_ pid: Int32, at now: Date) {
        pausedByUs.append(pid)
        lastAction = now
    }

    func didResume(_ pid: Int32, at now: Date) {
        pausedByUs.removeAll { $0 == pid }
        lastAction = now
    }

    func forget(_ pid: Int32) {
        pausedByUs.removeAll { $0 == pid }
    }
}
