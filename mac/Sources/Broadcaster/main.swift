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

        // Frame rate is the knob the product actually has, so the sweep moves it
        // and holds the payload at the size a real frame measured. What comes
        // out is how many frames a second the link will carry before latency
        // starts climbing — which is the number the mirror has to be built to.
        // Two passes over the same rates, and no rate so low that a percentile
        // is one unlucky payload. The previous sweep read as though load made
        // the link faster, which is not a thing that happens — it was noise with
        // too few samples to argue with.
        let sweeping = arguments.contains("--sweep")
        let rates = sweeping ? [10, 15, 20, 30, 10, 15, 20, 30] : [fps]
        print("connected to \(peer.displayName). Payload \(size / 1024) KB, \(reliable ? "reliable" : "unreliable").")

        if sweeping {
            print("\n  pass   fps   offered      p50      p95      max    lost   stalls")
            print("  ----   ---   -------   ------   ------   ------   -----   ------")
        }

        for (index, rate) in rates.enumerated() {
            let frames = sweeping ? rate * 10 : count
            let reading = await link.probe(count: frames, size: size, fps: rate, reliable: reliable)
            let seconds = Double(frames) / Double(rate)
            let mbps = Double(reading.bytesSent) * 8 / seconds / 1_000_000

            if sweeping {
                if reading.isSilent {
                    print(String(
                        format: "  %4d   %3d   %5.2f M   nothing came back — run is broken, not lossy",
                        index / 4 + 1, rate, mbps
                    ))
                } else {
                    print(String(
                        format: "  %4d   %3d   %5.2f M   %5.0fms   %5.0fms   %5.0fms   %4.0f%%   %3d/%d",
                        index / 4 + 1, rate, mbps,
                        reading.percentile(0.5) * 1000,
                        reading.percentile(0.95) * 1000,
                        reading.percentile(1.0) * 1000,
                        reading.lossPercent,
                        reading.stalls, reading.echoed
                    ))
                }
            } else {
                print("""

                sent        \(reading.sent) payloads, \(reading.bytesSent / 1024) KB total
                throughput  \(String(format: "%.2f", mbps)) Mbps offered
                echoed      \(reading.echoed), \(reading.lost) lost (\(String(format: "%.1f", reading.lossPercent))%)
                round trip  p50 \(String(format: "%.0f", reading.percentile(0.5) * 1000)) ms, \
                p95 \(String(format: "%.0f", reading.percentile(0.95) * 1000)) ms, \
                max \(String(format: "%.0f", reading.percentile(1.0) * 1000)) ms
                stalls      \(reading.stalls) of \(reading.echoed) over \(Int(PeerLink.stallThreshold * 1000))ms
                link        \(reading.lostPeerAtSecond.map { String(format: "peer went away %.0fs in — the rest of this run had nobody to talk to", $0) } ?? "peer present for the whole run")\(reading.sendFailures > 0 ? ", \(reading.sendFailures) sends refused" : "")
                one way     about \(String(format: "%.0f", reading.percentile(0.95) * 500)) ms at p95, \
                taking half the round trip — an assumption, not a measurement
                """)

                // Stalls cluster rather than spread, so where they fall matters
                // as much as how many there are: a mirror can ride out a freeze
                // by skipping to the present, but not if freezes never end.
                if reading.timeline.count > 60, seconds >= 60 {
                    print("\n            stalls per 30s: ", terminator: "")
                    let buckets = Int(ceil(seconds / 30))
                    for bucket in 0..<buckets {
                        let window = reading.timeline.filter {
                            $0.offset >= Double(bucket) * 30 && $0.offset < Double(bucket + 1) * 30
                        }
                        let stalled = window.filter { $0.roundTrip > PeerLink.stallThreshold }.count
                        print("\(stalled)", terminator: bucket == buckets - 1 ? "\n" : " ")
                    }
                }
            }

            // Let whatever queued during the last rate drain, or its backlog
            // would be charged to the next one.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        if sweeping {
            print("""

            Read the two passes against each other. A rate that is slow in both is a
            limit; one that is slow in only one is the link stalling, which it does
            regardless of load. "Stalls" counts payloads over \(Int(PeerLink.stallThreshold * 1000))ms and survives a
            short run better than p95 does.

            Nothing was lost at any rate in the first sweep even in unreliable mode, so
            the broadcaster has to stop sending of its own accord — the transport will
            queue what it cannot carry rather than discard it, and a mirror built to
            trust it runs further behind the longer it is watched.
            """)
        }
    } catch {
        print("link probe failed: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// The mirror itself: capture, compress, send. Every part of this was measured
// on its own first, and the two rules below are the only things those
// measurements said the design must do.
if arguments.contains("--mirror") {
    let link = PeerLink()
    let capture = ScreenCapture()
    var encoder: FrameEncoder?
    var sent = 0
    var droppedInFlight = 0
    var keyframesSent = 0
    var keyframesRequested = 0
    var frameSequence: UInt32 = 0
    let startedAt = Date()

    print("advertising as \"\(PeerLink.serviceType)\". Open the app on the phone and start the mirror…")

    do {
        let peer = try await link.waitForPeer(timeout: 120)
        print("connected to \(peer.displayName). Mirroring at up to \(fps) fps, \(bitrateMbps) Mbps ceiling. Ctrl-C to stop.")

        capture.onFrame = { pixelBuffer, time in
            if encoder == nil {
                encoder = try? FrameEncoder(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer),
                    fps: fps,
                    bitrate: bitrateMbps * 1_000_000
                )
                encoder?.onEncoded = { frame, isKeyframe, parameterSets in
                    frameSequence &+= 1
                    let packet = FramePacket.encodeFrame(
                        sequence: frameSequence,
                        frame: frame,
                        isKeyframe: isKeyframe,
                        parameterSets: parameterSets,
                        elapsedMilliseconds: UInt64(Date().timeIntervalSince(startedAt) * 1000)
                    )
                    if link.sendFrame(packet, sequence: frameSequence, isKeyframe: isKeyframe) {
                        sent += 1
                        if isKeyframe { keyframesSent += 1 }
                    } else {
                        droppedInFlight += 1
                    }
                }
            }

            // The viewer asks when it notices a gap. Answering costs one frame;
            // ignoring it leaves the picture decoding against something it never
            // received until the next scheduled keyframe two seconds later.
            if link.takeKeyframeRequest() {
                encoder?.requestKeyframe()
                keyframesRequested += 1
            }
            encoder?.submit(pixelBuffer, at: time)
        }

        // Runs until interrupted. Capture is measured the whole time so the
        // numbers printed at the end describe the mirror rather than a bench.
        let reading = try await capture.run(seconds: seconds, fps: fps, atPointScale: !usePixels)
        let encoded = encoder?.finish()

        print("""

        captured    \(reading.delivered) frames with new content over \(Int(seconds))s
        sent        \(sent) frames, \(droppedInFlight) held back because the phone had not caught up
        keyframes   \(keyframesSent) sent, \(keyframesRequested) of them asked for after a gap
        encoded     \(encoded?.frames ?? 0) frames, \(encoded.map { $0.meanBytes / 1024 } ?? 0) KB mean
        link        \(link.hasPeer ? "peer still connected" : "peer gone")
        """)
    } catch {
        print("mirror failed: \(error.localizedDescription)")
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
