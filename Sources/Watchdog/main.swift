import AppKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--status") {
    let sample = Sampler.take(history: History())
    let verdict = Rules.evaluate(sample, thresholds: Thresholds.load())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(StatusReport(sample: sample, verdict: verdict))
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

if arguments.contains("--saved") || arguments.contains("--resume-saved") {
    let log = EventLog()
    let store = SavedSessionStore(directory: SavedSessionStore.defaultDirectory(logDirectory: log.directory))
    if let i = arguments.firstIndex(of: "--resume-saved"), i + 1 < arguments.endIndex, let s = store.sessions.first(where: { $0.sessionId == arguments[i + 1] }) {
        switch store.launch(s) {
        case .success(let how):
            store.remove(sessionId: s.sessionId)
            print(how)
        case .failure(let error):
            print("failed: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
    for s in store.sessions {
        print("\(s.sessionId)  \(s.name)  \(Format.gb(s.treeBytes))  quit \(s.quitAt)  (\(s.reason))  cd \(SavedSessionStore.shellQuote(s.cwd)) && \(s.resumeCommand)")
    }
    if store.sessions.isEmpty { print("no saved sessions in \(store.fileURL.path)") }
    exit(0)
}

if arguments.contains("--enable-login") {
    print(LoginItem.enable())
    exit(0)
}

if arguments.contains("--disable-login") {
    print(LoginItem.disable())
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
