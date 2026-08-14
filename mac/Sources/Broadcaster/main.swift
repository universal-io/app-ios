import CoreMedia
import Foundation

// Answers two questions, in the order they matter, with no transport involved —
// so a poor reading cannot be blamed on MultipeerConnectivity and a good one
// cannot be credited to it.
//
//   1. Does ScreenCaptureKit hand over frames at the rate and size asked for?
//   2. What do those frames cost to carry once compressed?
//
// The second is the number the transport has to survive. Screen content is
// mostly still, so it may turn out that mirroring is not a video problem at all.

let arguments = CommandLine.arguments
func value(for flag: String, default fallback: Int) -> Int {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return fallback }
    return Int(arguments[index + 1]) ?? fallback
}

let seconds = Double(value(for: "--seconds", default: 5))
let fps = value(for: "--fps", default: 30)
let bitrateMbps = value(for: "--mbps", default: 8)
let usePixels = arguments.contains("--pixels")
let shouldEncode = arguments.contains("--encode")

// The transport is measured on its own, with payloads the size of the frames
// already measured rather than with the frames themselves — so a bad number
// here cannot be blamed on capture or encoding.
if arguments.contains("--link") {
    let link = PeerLink()
    let size = value(for: "--bytes", default: 30 * 1024)
    let count = value(for: "--frames", default: 300)
    let reliable = arguments.contains("--reliable")

    print("""
    advertising as "\(PeerLink.serviceType)". Open the app on the phone and start the mirror probe…
    """)

    do {
        let peer = try await link.waitForPeer(timeout: 60)
        print("connected to \(peer.displayName). Sending \(count) payloads of \(size / 1024) KB at \(fps)/s, \(reliable ? "reliable" : "unreliable")…")

        let reading = await link.probe(count: count, size: size, fps: fps, reliable: reliable)
        let seconds = Double(count) / Double(fps)

        print("""

        sent        \(reading.sent) payloads, \(reading.bytesSent / 1024) KB total
        throughput  \(String(format: "%.2f", Double(reading.bytesSent) * 8 / seconds / 1_000_000)) Mbps offered
        echoed      \(reading.echoed), \(reading.lost) lost (\(String(format: "%.1f", reading.lossPercent))%)
        round trip  p50 \(String(format: "%.0f", reading.percentile(0.5) * 1000)) ms, \
        p95 \(String(format: "%.0f", reading.percentile(0.95) * 1000)) ms, \
        max \(String(format: "%.0f", reading.percentile(1.0) * 1000)) ms
        one way     about \(String(format: "%.0f", reading.percentile(0.95) * 500)) ms at p95, \
        taking half the round trip — an assumption, not a measurement
        """)
    } catch {
        print("link probe failed: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

let capture = ScreenCapture()
var encoder: FrameEncoder?

do {
    print("capturing for \(Int(seconds))s at up to \(fps) fps, \(usePixels ? "backing pixels" : "points")…")
    if shouldEncode {
        print("encoding H.264 with a \(bitrateMbps) Mbps ceiling. Scroll or type while this runs — a still screen flatters the result.")
    }

    // The encoder needs the frame size, which is only known once frames arrive.
    if shouldEncode {
        capture.onFrame = { pixelBuffer, time in
            if encoder == nil {
                encoder = try? FrameEncoder(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer),
                    fps: fps,
                    bitrate: bitrateMbps * 1_000_000
                )
            }
            encoder?.submit(pixelBuffer, at: time)
        }
    }

    let reading = try await capture.run(seconds: seconds, fps: fps, atPointScale: !usePixels)
    let achieved = Double(reading.delivered) / seconds

    print("""

    display     \(Int(capture.displayPointSize.width))x\(Int(capture.displayPointSize.height)) points \
    / \(Int(capture.displayPixelSize.width))x\(Int(capture.displayPixelSize.height)) pixels
    frames      \(reading.delivered) with new content, \(reading.incomplete) unchanged
    samples     \(String(format: "%.1f", Double(reading.delivered + reading.incomplete) / seconds)) per second \
    of \(fps) requested — this is the pipeline's rate, changed or not
    changed     \(String(format: "%.1f", achieved)) fps actually carried new pixels
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
        Recording for whichever terminal launched it, restart that terminal, \
        and run this again. The first attempt is expected to fail.
        """)
        exit(1)
    }

    if let encoded = encoder?.finish() {
        print("""

        encoded     \(encoded.frames) frames, \(encoded.keyframes) of them keyframes
        dropped     \(encoded.droppedBusy) of \(encoded.submitted) submitted, because the encoder was still busy
        bandwidth   \(String(format: "%.2f", encoded.megabitsPerSecond(over: seconds))) Mbps sustained
        per frame   \(encoded.meanBytes / 1024) KB mean, \(encoded.largestFrame / 1024) KB largest
        latency     \(String(format: "%.1f", encoded.meanLatencyMilliseconds)) ms from submit to compressed \
        (queueing included — not a measure of work done)
        """)
    }
} catch {
    print("capture failed: \(error.localizedDescription)")
    exit(1)
}
