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
    private static var commandURL: URL? { container?.appendingPathComponent("command.txt") }
    private static let liveStaleInterval: TimeInterval = 3

    enum LivePhase: String, Codable {
        case recording
        case paused
    }

    enum Command: String {
        case pause
        case resume
        case end
    }

    private struct Live: Codable {
        var session: Double   // 0 == no active session
        var updatedAt: Double
        var phase: LivePhase
        var finalized: String
        var volatile: String
    }

    // MARK: App side

    /// Session id held in the (single) app process; written into every update.
    private static var currentSession: Double = 0
    private static var currentPhase: LivePhase = .recording
    private static var lastFinalized = ""
    private static var lastVolatile = ""

    static func startLiveSession() {
        currentSession = Date().timeIntervalSince1970
        currentPhase = .recording
        lastFinalized = ""
        lastVolatile = ""
        writeCurrentLive()
        writeConsumed(0)
    }

    static func endLiveSession() {
        currentSession = 0
        currentPhase = .paused
        lastFinalized = ""
        lastVolatile = ""
        writeLive(Live(session: 0, updatedAt: Date().timeIntervalSince1970, phase: .paused, finalized: "", volatile: ""))
    }

    static func publishLive(finalized: String, volatile: String) {
        guard currentSession > 0 else { return }
        currentPhase = .recording
        lastFinalized = finalized
        lastVolatile = volatile
        writeCurrentLive()
    }

    static func heartbeatLiveSession() {
        guard currentSession > 0 else { return }
        writeCurrentLive()
    }

    static func pauseLiveSession() {
        guard currentSession > 0 else { return }
        currentPhase = .paused
        lastFinalized = ""
        lastVolatile = ""
        writeConsumed(0)
        writeCurrentLive()
    }

    static func resumeLiveSession() {
        guard currentSession > 0 else { return }
        currentPhase = .recording
        lastFinalized = ""
        lastVolatile = ""
        writeConsumed(0)
        writeCurrentLive()
    }

    // MARK: Keyboard side

    struct LiveState {
        let phase: LivePhase
        let finalized: String
        let volatile: String
        let consumed: Int
    }

    static func readLive() -> LiveState? {
        guard let live = readLiveFile(), live.session > 0 else { return nil }
        guard Date().timeIntervalSince1970 - live.updatedAt <= liveStaleInterval else { return nil }
        return LiveState(phase: live.phase, finalized: live.finalized, volatile: live.volatile, consumed: readConsumed())
    }

    static func setConsumed(_ count: Int) {
        writeConsumed(count)
    }

    static func requestPause() {
        writeCommand(.pause)
    }

    static func requestResume() {
        writeCommand(.resume)
    }

    static func requestEnd() {
        writeCommand(.end)
    }

    static func readCommand() -> Command? {
        guard let commandURL,
              let string = try? String(contentsOf: commandURL, encoding: .utf8) else { return nil }
        let name = string.split(separator: ":").first.map(String.init) ?? ""
        return Command(rawValue: name)
    }

    static func clearCommand() {
        guard let commandURL else { return }
        try? Data("".utf8).write(to: commandURL, options: .atomic)
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
        clearCommand()
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

    private static func writeCurrentLive() {
        writeLive(
            Live(
                session: currentSession,
                updatedAt: Date().timeIntervalSince1970,
                phase: currentPhase,
                finalized: lastFinalized,
                volatile: lastVolatile
            )
        )
    }

    private static func writeCommand(_ command: Command) {
        guard let commandURL else { return }
        let payload = "\(command.rawValue):\(Date().timeIntervalSince1970)"
        try? Data(payload.utf8).write(to: commandURL, options: .atomic)
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
