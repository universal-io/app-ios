import Foundation

/// Hand-off channel between the host app and the keyboard extension, backed by
/// files in the shared App Group container.
///
/// Files (not UserDefaults) are used on purpose: cross-process UserDefaults is
/// cached by cfprefsd and propagates with large, unpredictable delay. Atomic
/// file writes are read fresh every poll, which keeps live dictation low-latency.
///
/// Background-audio model (POC): the app keeps recording after a one-time
/// activation and streams the live transcript here. The keyboard, while visible
/// in the host app, injects newly finalized text in place — no per-use switch.
enum SharedStore {
    static let suiteName = "group.com.matsumotokaya.bombsquad"

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }
    private static var liveURL: URL? { container?.appendingPathComponent("live.json") }
    private static var consumedURL: URL? { container?.appendingPathComponent("consumed.txt") }

    private struct Live: Codable {
        var session: Double   // 0 == no active session
        var finalized: String
        var volatile: String
    }

    // MARK: App side

    /// Session id held in the (single) app process; written into every update.
    private static var currentSession: Double = 0

    static func startLiveSession() {
        currentSession = Date().timeIntervalSince1970
        writeLive(Live(session: currentSession, finalized: "", volatile: ""))
        writeConsumed(0)
    }

    static func endLiveSession() {
        currentSession = 0
        writeLive(Live(session: 0, finalized: "", volatile: ""))
    }

    static func publishLive(finalized: String, volatile: String) {
        guard currentSession > 0 else { return }
        writeLive(Live(session: currentSession, finalized: finalized, volatile: volatile))
    }

    // MARK: Keyboard side

    struct LiveState {
        let finalized: String
        let volatile: String
        let consumed: Int
    }

    static func readLive() -> LiveState? {
        guard let live = readLiveFile(), live.session > 0 else { return nil }
        return LiveState(finalized: live.finalized, volatile: live.volatile, consumed: readConsumed())
    }

    static func setConsumed(_ count: Int) {
        writeConsumed(count)
    }

    // MARK: Stop signal (keyboard -> background app)

    private static var stopURL: URL? { container?.appendingPathComponent("stop.txt") }

    /// Keyboard: ask the background app to end the session.
    static func requestStop() {
        guard let stopURL else { return }
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: stopURL, options: .atomic)
    }

    /// App: clear the flag at the start of a session.
    static func clearStopRequest() {
        guard let stopURL else { return }
        try? Data("0".utf8).write(to: stopURL, options: .atomic)
    }

    /// App: has a stop been requested?
    static func isStopRequested() -> Bool {
        guard let stopURL,
              let string = try? String(contentsOf: stopURL, encoding: .utf8) else { return false }
        return (Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    // MARK: File IO

    private static func writeLive(_ live: Live) {
        guard let liveURL, let data = try? JSONEncoder().encode(live) else { return }
        try? data.write(to: liveURL, options: .atomic)
    }

    private static func readLiveFile() -> Live? {
        guard let liveURL, let data = try? Data(contentsOf: liveURL) else { return nil }
        return try? JSONDecoder().decode(Live.self, from: data)
    }

    private static func writeConsumed(_ count: Int) {
        guard let consumedURL else { return }
        try? Data("\(count)".utf8).write(to: consumedURL, options: .atomic)
    }

    private static func readConsumed() -> Int {
        guard let consumedURL,
              let string = try? String(contentsOf: consumedURL, encoding: .utf8) else { return 0 }
        return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
