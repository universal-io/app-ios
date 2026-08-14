import Foundation

// Answers one question: does ScreenCaptureKit hand over frames at the rate it
// was asked for, and at the size analysis wants? Transport is not involved, so
// a poor result here cannot be blamed on MultipeerConnectivity and a good one
// cannot be credited to it.

let arguments = CommandLine.arguments
func value(for flag: String, default fallback: Int) -> Int {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return fallback }
    return Int(arguments[index + 1]) ?? fallback
}

let seconds = Double(value(for: "--seconds", default: 5))
let fps = value(for: "--fps", default: 30)
let usePixels = arguments.contains("--pixels")

let capture = ScreenCapture()

do {
    print("capturing for \(Int(seconds))s at up to \(fps) fps, \(usePixels ? "backing pixels" : "points")…")
    let reading = try await capture.run(seconds: seconds, fps: fps, atPointScale: !usePixels)

    let achieved = Double(reading.delivered) / seconds
    print("""

    display     \(Int(capture.displayPointSize.width))x\(Int(capture.displayPointSize.height)) points \
    / \(Int(capture.displayPixelSize.width))x\(Int(capture.displayPixelSize.height)) pixels
    frames      \(reading.delivered) complete, \(reading.incomplete) without new content
    rate        \(String(format: "%.1f", achieved)) fps delivered of \(fps) requested
    frame size  \(Int(reading.pixelSize.width))x\(Int(reading.pixelSize.height))
    first frame \(reading.firstFrameDelay.map { String(format: "%.0f ms", $0 * 1000) } ?? "never arrived")
    """)

    if let stopped = reading.stoppedWith {
        print("stopped early: \(stopped)")
    }
    if reading.delivered == 0 {
        print("""

        No frames arrived. This is almost always Screen Recording permission \
        rather than the code: macOS grants it to the program that runs this, so \
        check System Settings > Privacy & Security > Screen & System Audio \
        Recording for whichever terminal launched it, and run it again after \
        granting. The permission is only requested on a real attempt, so the \
        first run is expected to fail.
        """)
        exit(1)
    }
} catch {
    print("capture failed: \(error.localizedDescription)")
    exit(1)
}
