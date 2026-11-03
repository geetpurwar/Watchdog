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
