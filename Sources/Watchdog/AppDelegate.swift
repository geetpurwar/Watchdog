import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var timer: DispatchSourceTimer?
    private var termSource: DispatchSourceSignal?
    private var activity: NSObjectProtocol?
    private let queue = DispatchQueue(label: "watchdog.sampler", qos: .utility)
    private let history = History()
    private let log = EventLog()
    private let thresholds = Thresholds.load()
    private let pilot = AutoPilot()
    /// Decided once at launch. Asking launchctl later would block the menu under memory pressure.
    private let managedByLaunchd = LoginItem.detectManaged()

    private var latest: Sample?
    private var verdict = Verdict(level: .green, reasons: [])
    /// The colour on screen. Goes up at once, comes down only after `calmSamples` quiet readings.
    private var shown: Level = .green
    private var calmStreak = 0
    private let calmSamples = 3
    private let interval: TimeInterval = 10
    private let redReminderEvery: TimeInterval = 120
    private var lastRedReminder = Date.distantPast
    private var notificationsAllowed = false
    private var notificationsDecided = false
    private var pendingAnnouncement: (level: Level, reasons: [String], sample: Sample)?
    /// Reason keys seen in the previous reading, and when each key was last announced.
    private var previousKeys = Set<String>()
    private var lastAnnouncedAt: [String: Date] = [:]
    private let sameKeyCooldown: TimeInterval = 10 * 60
    private var clearDevSpace: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Clear-Dev-Space.command")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy is enough. A second double-click, or a stray launch, steps aside for the running one.
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != getpid() }
            if !others.isEmpty {
                log.event("another Watchdog is already running (pid \(others.map { String($0.processIdentifier) }.joined(separator: ","))); this one exits")
                log.flush()
                exit(0)
            }
        }
        // A raw test copy (fake pressure or a fake session path, no bundle) stays out of the menu bar.
        let env = ProcessInfo.processInfo.environment
        let testMode = Bundle.main.bundleIdentifier == nil
            && (env["WATCHDOG_SESSION_PATH"] != nil || env["WATCHDOG_FAKE_PRESSURE"] != nil || env["WATCHDOG_FAKE_PRESSURE_FILE"] != nil)
        if !testMode {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Icon.dot(.green)
            item.button?.toolTip = "Watchdog: checking…"
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }

        // Keep App Nap from stretching the 10 s timer while we sit idle in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Watchdog samples memory every 10 s")

        // launchctl bootout sends SIGTERM; log it instead of vanishing.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.log.event("stopped (SIGTERM) pid=\(getpid())")
            self?.log.flush()
            exit(0)
        }
        term.resume()
        termSource = term

        setUpNotifications()
        log.event("started pid=\(getpid()) launchd=\(managedByLaunchd) bundle=\(Bundle.main.bundleIdentifier ?? "none") auto=\(pilot.enabled) remembered paused=\(pilot.pausedByUs) menubar=\(statusItem != nil) log=\(log.directory.path)")

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.event("stopped pid=\(getpid())")
        log.flush()
    }

    // MARK: - Sampling

    private func tick() {
        let sample = Sampler.take(history: history)
        let v = Rules.evaluate(sample, thresholds: thresholds)
        log.sample(sample, level: v.level)
        DispatchQueue.main.async { [self] in apply(sample, v) }
    }

    private func apply(_ sample: Sample, _ v: Verdict) {
        latest = sample
        verdict = v

        let before = shown
        if v.level > shown {
            shown = v.level
            calmStreak = 0
        } else if v.level < shown {
            calmStreak += 1
            if calmStreak >= calmSamples {
                shown = v.level
                calmStreak = 0
            }
        } else {
            calmStreak = 0
        }

        let now = Date()
        let keysNow = Set(v.reasons.map(\.key))
        let newKeys = keysNow.subtracting(previousKeys)
        previousKeys = keysNow

        if shown != before {
            let why = v.texts.isEmpty ? "all clear" : v.texts.joined(separator: " | ")
            log.event("level \(before.name) -> \(shown.name): \(why) top=\(topSummary(sample))")
            announce(level: shown, reasons: v.texts, sample: sample)
            for k in keysNow { lastAnnouncedAt[k] = now }
        } else if shown != .green, !newKeys.isEmpty {
            // Same colour, but something new went wrong (e.g. RAM pressure while the disk was already orange).
            let fresh = v.reasons.filter { newKeys.contains($0.key) && now.timeIntervalSince(lastAnnouncedAt[$0.key] ?? .distantPast) >= sameKeyCooldown }
            if !fresh.isEmpty {
                log.event("new problem at \(shown.name): \(fresh.map(\.text).joined(separator: " | "))")
                announce(level: shown, reasons: fresh.map(\.text), sample: sample)
                for r in fresh { lastAnnouncedAt[r.key] = now }
            }
        } else if shown == .red, now.timeIntervalSince(lastRedReminder) >= redReminderEvery {
            announce(level: .red, reasons: v.texts, sample: sample)
        }

        statusItem?.button?.image = Icon.dot(shown)
        statusItem?.button?.toolTip = "Watchdog: \(shown.title)" + (v.texts.isEmpty ? "" : " — " + v.texts.joined(separator: " "))

        for s in pilot.adopt(sessions: sample.sessions) {
            log.event("adopted paused session '\(s.label)' pid \(s.pid) (paused with its shell by an earlier Watchdog); will resume it when memory is calm")
        }
        if let decision = pilot.decide(sample: sample, verdict: v, shown: shown, now: now) {
            perform(decision, now: now)
        }
    }

    private func topSummary(_ s: Sample) -> String {
        s.topProcesses.prefix(5).map { "\($0.name)(\($0.pid)) \(Format.gb($0.footprintBytes))" }.joined(separator: ", ")
    }

    // MARK: - Auto mode

    private func perform(_ decision: AutoPilot.Decision, now: Date) {
        switch decision {
        case .pause(let s):
            let o = SessionControl.pause(pid: s.pid, shell: s.shellPid)
            pilot.didPause(s.pid, at: now)
            log.event("auto paused session '\(s.label)' pid \(s.pid) (\(Format.gb(s.treeBytes)) in \(s.treeCount) processes, shell \(s.shellPid.map(String.init) ?? "none")): \(o.description)")
            notify(title: "Watchdog paused a Claude session",
                   body: "The session in \(s.label) (\(Format.gb(s.treeBytes)) with its tools) is paused to protect the Mac. It resumes by itself once memory calms down.",
                   sound: true, id: "watchdog-auto")
        case .resume(let s):
            let o = SessionControl.resume(pid: s.pid, shell: s.shellPid)
            pilot.didResume(s.pid, at: now)
            log.event("auto resumed session '\(s.label)' pid \(s.pid): \(o.description)")
            notify(title: "Watchdog resumed a Claude session",
                   body: "Memory has calmed down. The session in \(s.label) is running again.",
                   sound: false, id: "watchdog-auto")
        }
        checkNow()
    }

    // MARK: - Notifications

    private func setUpNotifications() {
        guard Bundle.main.bundleIdentifier != nil else {
            notificationsDecided = true
            log.event("notifications off: not running from an app bundle")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.notificationsAllowed = granted
                self.notificationsDecided = true
                self.log.event("notifications \(granted ? "allowed" : "denied")\(error.map { " error=\($0)" } ?? "")")
                if let p = self.pendingAnnouncement {
                    self.pendingAnnouncement = nil
                    self.announce(level: p.level, reasons: p.reasons, sample: p.sample)
                }
            }
        }
    }

    private func announce(level: Level, reasons: [String], sample: Sample) {
        let title: String
        var body = reasons.joined(separator: " ")
        switch level {
        case .green:
            title = "Watchdog: back to normal"
            body = "Memory, swap and disk have room again."
        case .orange:
            title = "Watchdog: warning"
        case .red:
            title = pilot.enabled ? "Watchdog: DANGER" : "Watchdog: DANGER, pause some sessions"
            lastRedReminder = Date()
        }
        if level != .green, let top = sample.topProcesses.first {
            body += " Biggest: \(top.name) \(Format.gb(top.footprintBytes))."
        }
        guard notificationsDecided else {
            // Permission is still being asked for; send this one as soon as we know.
            pendingAnnouncement = (level, reasons, sample)
            log.event("notify deferred (permission pending): \(title)")
            return
        }
        // One identifier per colour, so a repeated red reminder replaces the last one instead of piling up.
        notify(title: title, body: body, sound: level != .green, critical: level == .red, id: "watchdog-\(level.name)")
    }

    private func notify(title: String, body: String, sound: Bool, critical: Bool = false, id: String) {
        guard notificationsAllowed else {
            log.event("notify skipped (not allowed): \(title)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if critical { content.sound = .defaultCritical } else if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            self?.log.event("notified '\(title)'\(error.map { " error=\($0)" } ?? "")")
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let s = latest else {
            menu.addItem(info("Checking…"))
            return
        }

        let header = NSMenuItem(title: "Mac health: \(shown.title)", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: "Mac health: \(shown.title)", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: Icon.color(shown),
        ])
        header.isEnabled = false
        menu.addItem(header)

        if verdict.reasons.isEmpty {
            menu.addItem(info("Memory, swap and disk all have room."))
        } else {
            for r in verdict.texts { menu.addItem(info("• " + r)) }
            if shown == .red, !pilot.enabled {
                menu.addItem(info("Pause or quit a session below."))
            }
        }
        menu.addItem(.separator())

        let pressure: String
        switch s.pressureLevel {
        case 4...: pressure = "Critical"
        case 3: pressure = "Urgent"
        case 2: pressure = "Warning"
        default: pressure = "Normal"
        }
        menu.addItem(info("Memory pressure: \(pressure)"))
        menu.addItem(info("Memory used: \(Format.gb(s.usedBytes)) of \(Format.gb(s.totalBytes, decimals: 0)) (\(Format.gb(s.compressedBytes)) compressed)"))
        var swapLine = "Swap: \(Format.gb(s.swapUsedBytes))"
        if s.swapOutBytesPerSec >= 1_048_576 { swapLine += ", writing \(Format.mbps(s.swapOutBytesPerSec))" }
        if s.swapGrowth2mBytes >= 104_857_600 { swapLine += ", up \(Format.gb(s.swapGrowth2mBytes)) in 2 min" }
        menu.addItem(info(swapLine))
        var diskLine = "Disk free: \(Format.gb(s.diskFreeBytes, decimals: 0)) of \(Format.gb(s.diskTotalBytes, decimals: 0)) (\(String(format: "%.1f", s.diskFreePercent))%)"
        if s.diskFreeImportantBytes > s.diskFreeBytes + 1_073_741_824 {
            diskLine += ", Finder says \(Format.gb(s.diskFreeImportantBytes, decimals: 0))"
        }
        menu.addItem(info(diskLine))
        menu.addItem(info("Disk writes: \(Format.mbps(s.diskWriteBytesPerSec)), \(String(format: "%.1f", s.diskWriteLatencyMs)) ms each"))
        menu.addItem(info("Load: \(Int(s.load1.rounded())) on \(s.cpuCount) cores"))
        menu.addItem(.separator())

        // Sessions
        menu.addItem(info("Claude Code sessions: \(s.claudeCount) using \(Format.gb(s.claudeBytes)) with their tools"))
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        for session in s.sessions {
            var title = "\(Format.gb(session.treeBytes))   \(session.label)"
            if !session.tty.isEmpty { title += "   \(session.tty)" }
            if session.startedAt > .distantPast { title += ", since \(clock.string(from: session.startedAt))" }
            if session.paused {
                title += pilot.pausedByUs.contains(session.pid) ? "  — paused by Watchdog" : "  — paused"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.indentationLevel = 1
            item.toolTip = "\(session.cwd)\npid \(session.pid), \(session.treeCount) processes"
            let sub = NSMenu()
            if session.paused {
                sub.addItem(action("Resume", #selector(resumeSession(_:)), session.pid))
            } else {
                sub.addItem(action("Pause (keeps its memory, stops its work)", #selector(pauseSession(_:)), session.pid))
            }
            sub.addItem(action("Quit (frees its memory)", #selector(quitSession(_:)), session.pid))
            item.submenu = sub
            menu.addItem(item)
        }
        let auto = action("Auto mode: pause sessions when red, resume when calm", #selector(toggleAuto))
        auto.state = pilot.enabled ? .on : .off
        menu.addItem(auto)
        if !pilot.pausedByUs.isEmpty {
            menu.addItem(action("Resume every session Watchdog paused", #selector(resumeAllAuto)))
        }
        menu.addItem(.separator())

        menu.addItem(info("Biggest processes (yours; system ones cannot be measured)"))
        for p in s.topProcesses.prefix(6) {
            let title = "\(Format.gb(p.footprintBytes))   \(p.name) (\(p.pid))" + (p.paused ? "  — paused" : "")
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.indentationLevel = 1
            if p.ownedByMe {
                let sub = NSMenu()
                if p.paused {
                    sub.addItem(action("Resume it and its children", #selector(resumeProcess(_:)), p.pid))
                } else {
                    sub.addItem(action("Pause it and its children", #selector(pauseProcess(_:)), p.pid))
                }
                sub.addItem(action("Quit it and its children", #selector(quitProcess(_:)), p.pid))
                item.submenu = sub
            } else {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(action("Check now", #selector(checkNow)))
        menu.addItem(action("Open log folder", #selector(openLogs)))
        if clearDevSpace != nil {
            menu.addItem(action("Free disk space (Clear-Dev-Space)…", #selector(runClearDevSpace)))
        }
        let login = action("Start at login", #selector(toggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action(managedByLaunchd ? "Quit until next login" : "Quit Watchdog", #selector(quitSelf)))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, _ pid: Int32? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        if let pid { item.representedObject = NSNumber(value: pid) }
        return item
    }

    private func pid(from sender: Any?) -> Int32? {
        ((sender as? NSMenuItem)?.representedObject as? NSNumber)?.int32Value
    }

    private func session(from sender: Any?) -> SessionRow? {
        guard let pid = pid(from: sender) else { return nil }
        return latest?.sessions.first { $0.pid == pid }
    }

    // MARK: - Actions

    @objc private func pauseSession(_ sender: Any?) {
        guard let s = session(from: sender) else { return }
        let o = SessionControl.pause(pid: s.pid, shell: s.shellPid)
        log.event("user paused session '\(s.label)' pid \(s.pid): \(o.description)")
        checkNow()
    }

    @objc private func resumeSession(_ sender: Any?) {
        guard let s = session(from: sender) else { return }
        let o = SessionControl.resume(pid: s.pid, shell: s.shellPid)
        pilot.forget(s.pid)
        log.event("user resumed session '\(s.label)' pid \(s.pid): \(o.description)")
        checkNow()
    }

    @objc private func quitSession(_ sender: Any?) {
        guard let s = session(from: sender) else { return }
        if s.paused { _ = SessionControl.resume(pid: s.pid, shell: s.shellPid) }   // a stopped process cannot handle SIGTERM
        let o = SessionControl.quit(pid: s.pid)
        pilot.forget(s.pid)
        log.event("user quit session '\(s.label)' pid \(s.pid): \(o.description)")
        checkNow()
    }

    @objc private func resumeAllAuto() {
        guard let s = latest else { return }
        for pid in pilot.pausedByUs.reversed() {
            guard let session = s.sessions.first(where: { $0.pid == pid }) else { continue }
            let o = SessionControl.resume(pid: session.pid, shell: session.shellPid)
            log.event("user resumed auto-paused session '\(session.label)' pid \(pid): \(o.description)")
        }
        for pid in pilot.pausedByUs { pilot.forget(pid) }
        checkNow()
    }

    @objc private func toggleAuto() {
        pilot.enabled.toggle()
        log.event("user turned auto mode \(pilot.enabled ? "on" : "off")")
    }

    @objc private func pauseProcess(_ sender: Any?) {
        guard let pid = pid(from: sender) else { return }
        let o = SessionControl.pause(pid: pid, shell: Sampler.parentShell(of: pid))
        log.event("user paused pid \(pid) and its children: \(o.description)")
        checkNow()
    }

    @objc private func resumeProcess(_ sender: Any?) {
        guard let pid = pid(from: sender) else { return }
        let o = SessionControl.resume(pid: pid, shell: Sampler.parentShell(of: pid))
        log.event("user resumed pid \(pid) and its children: \(o.description)")
        checkNow()
    }

    @objc private func quitProcess(_ sender: Any?) {
        guard let pid = pid(from: sender) else { return }
        let o = SessionControl.quit(pid: pid)
        log.event("user quit pid \(pid) and its children: \(o.description)")
        checkNow()
    }

    @objc private func checkNow() {
        queue.async { [weak self] in self?.tick() }
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(log.directory)
    }

    @objc private func runClearDevSpace() {
        guard let url = clearDevSpace else { return }
        log.event("user opened Clear-Dev-Space")
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLogin() {
        if LoginItem.isEnabled {
            if managedByLaunchd {
                // Keep running now; just do not come back at the next login.
                LoginItem.removePlist()
                log.event("user turned Start at login off (still running until logout)")
            } else {
                LoginItem.disable()
                log.event("user turned Start at login off")
            }
        } else {
            let exe = Bundle.main.executablePath ?? LoginItem.installedExecutable
            if managedByLaunchd {
                // The job is already loaded; the plist alone makes it come back at login.
                let err = LoginItem.writePlist(executable: exe)
                log.event("user turned Start at login on: \(err ?? "ok")")
            } else {
                log.event("user turned Start at login on: \(LoginItem.enable(executable: exe))")
                // launchd now owns a fresh copy; this one steps aside.
                log.flush()
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func quitSelf() {
        log.event("user quit")
        log.flush()
        if managedByLaunchd {
            LoginItem.stopNow()   // sends SIGTERM to us; the handler above logs and exits
        }
        NSApp.terminate(nil)
    }
}

enum Icon {
    static func color(_ level: Level) -> NSColor {
        switch level {
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .red: return .systemRed
        }
    }

    static func dot(_ level: Level) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            color(level).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12)).fill()
            if level != .green {
                let text = NSAttributedString(string: "!", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 10),
                    .foregroundColor: NSColor.black.withAlphaComponent(0.8),
                ])
                let sz = text.size()
                text.draw(at: NSPoint(x: 9 - sz.width / 2, y: 9 - sz.height / 2))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
