import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the Mac's screen and reports what actually came out.
///
/// Reports rather than assumes: the requested frame interval is a request, and
/// ScreenCaptureKit is free to deliver fewer frames, drop them under load, or
/// hand back a different size than was asked for. Roadmap M4 is decided on
/// measured numbers, so the parts that can disagree with the request are all
/// counted separately.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Reading {
        var delivered = 0
        var incomplete = 0
        var pixelSize: CGSize = .zero
        var firstFrameDelay: TimeInterval?
        var stoppedWith: String?
    }

    private let lock = NSLock()
    private var reading = Reading()
    private var startedAt = Date()
    private var stream: SCStream?

    /// The display's size in points, which is the resolution analysis wants.
    /// Lessons section 3: Retina pixels cost tokens for nothing, and shrinking
    /// below points makes the model misread digits without saying so.
    private(set) var displayPointSize: CGSize = .zero
    private(set) var displayPixelSize: CGSize = .zero

    func run(seconds: TimeInterval, fps: Int, atPointScale: Bool) async throws -> Reading {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw Failure("No display to capture.")
        }

        displayPointSize = CGSize(width: display.width, height: display.height)
        displayPixelSize = CGSize(width: display.frame.width, height: display.frame.height)

        let configuration = SCStreamConfiguration()
        // Asking for points rather than backing pixels is the whole of the
        // resolution decision; it is cheaper and it reads better.
        configuration.width = Int(atPointScale ? displayPointSize.width : displayPixelSize.width)
        configuration.height = Int(atPointScale ? displayPointSize.height : displayPixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        // A short queue is deliberate. A backlog of stale frames is latency the
        // viewer cannot see the cause of; dropping is the better failure.
        configuration.queueDepth = 3

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))

        self.stream = stream
        startedAt = Date()
        try await stream.startCapture()

        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try? await stream.stopCapture()

        return lock.withLock { reading }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        lock.lock()
        defer { lock.unlock() }

        // A sample can arrive describing "nothing changed on screen". Counting
        // those as delivered frames would report a frame rate the viewer never
        // sees, which is exactly the kind of flattering number this is meant to
        // avoid producing.
        guard buffer.isValid, isComplete(buffer) else {
            reading.incomplete += 1
            return
        }

        if reading.firstFrameDelay == nil {
            reading.firstFrameDelay = Date().timeIntervalSince(startedAt)
        }
        if let image = CMSampleBufferGetImageBuffer(buffer) {
            reading.pixelSize = CGSize(
                width: CVPixelBufferGetWidth(image),
                height: CVPixelBufferGetHeight(image)
            )
        }
        reading.delivered += 1
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        reading.stoppedWith = error.localizedDescription
        lock.unlock()
    }

    private func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }

        return status == .complete
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
