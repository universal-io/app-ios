import Foundation

/// Counts what the mirror is doing, once a second, while it is doing it.
///
/// A summary at the end cannot tell a stutter from a slow average: the report
/// after the first mirroring run said frames were being sent, and the picture
/// was visibly jerky at the same time. Whether frames are being held back, or
/// simply never arriving from the screen, is a per-second question.
final class MirrorStats: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = 0
    private var sent = 0
    private var heldBack = 0
    private var keyframes = 0
    private var keyframeRequests = 0

    private var lastPrint = Date()
    private var totals = (captured: 0, sent: 0, heldBack: 0, keyframes: 0, requests: 0)

    func captureArrived() { lock.withLock { captured += 1 } }
    func frameSent(isKeyframe: Bool) {
        lock.withLock {
            sent += 1
            if isKeyframe { keyframes += 1 }
        }
    }
    func frameHeldBack() { lock.withLock { heldBack += 1 } }
    func keyframeRequested() { lock.withLock { keyframeRequests += 1 } }

    /// Prints a line and resets the second, if a second has passed.
    func tick() {
        let line: String? = lock.withLock {
            guard Date().timeIntervalSince(lastPrint) >= 1 else { return nil }
            defer {
                totals = (
                    totals.captured + captured,
                    totals.sent + sent,
                    totals.heldBack + heldBack,
                    totals.keyframes + keyframes,
                    totals.requests + keyframeRequests
                )
                captured = 0; sent = 0; heldBack = 0; keyframes = 0; keyframeRequests = 0
                lastPrint = Date()
            }
            return String(
                format: "  captured %2d   sent %2d   held %2d   keyframes %d%@",
                captured, sent, heldBack, keyframes,
                keyframeRequests > 0 ? "   (\(keyframeRequests) asked for)" : ""
            )
        }
        if let line { print(line) }
    }

    var summary: (captured: Int, sent: Int, heldBack: Int, keyframes: Int, requests: Int) {
        lock.withLock { totals }
    }
}
