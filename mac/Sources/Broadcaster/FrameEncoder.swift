import CoreMedia
import Foundation
import VideoToolbox

/// Compresses captured frames and reports what they cost to carry.
///
/// This is the number MultipeerConnectivity has to survive, and it is worth
/// knowing before any transport is written: a screen that mostly sits still
/// compresses to almost nothing, while one being scrolled does not, and the
/// difference decides whether the mirror is a video problem or a non-problem.
///
/// Encoding happens on its own queue. Doing it inline on the capture callback
/// throttles capture itself, which first showed up as a frame rate that looked
/// like a limit of ScreenCaptureKit and was actually this class standing in its
/// way. It is also wrong for the product: the broadcaster must not be able to
/// slow down the thing it is broadcasting.
///
/// Configured for live viewing rather than small files — no frame reordering,
/// so nothing waits on a later frame to be decodable, which would be latency
/// the viewer feels without ever seeing a cause.
final class FrameEncoder {
    struct Reading {
        var submitted = 0
        /// Frames thrown away because the encoder was still busy. Dropping is
        /// the correct real-time behavior (architecture section 2 says stale
        /// frames go in the bin), but it has to be counted or the bandwidth
        /// figure quietly describes a stream nobody would have watched.
        var droppedBusy = 0
        var frames = 0
        var keyframes = 0
        var bytes = 0
        var largestFrame = 0
        /// Submit to compressed output, including time spent queued. This is a
        /// latency, not a cost — the encoder is asynchronous, so wall time here
        /// says nothing about how much work it did.
        var latencySeconds: Double = 0

        var meanBytes: Int { frames == 0 ? 0 : bytes / frames }
        var meanLatencyMilliseconds: Double {
            frames == 0 ? 0 : latencySeconds / Double(frames) * 1000
        }
        func megabitsPerSecond(over seconds: Double) -> Double {
            seconds <= 0 ? 0 : Double(bytes) * 8 / seconds / 1_000_000
        }
    }

    /// Two frames in flight is enough to keep the encoder fed without letting a
    /// backlog build into latency.
    private static let maxInFlight = 2

    private let queue = DispatchQueue(label: "com.universalio.broadcaster.encode", qos: .userInitiated)
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var reading = Reading()
    private var inFlight = 0

    /// `bitrate` is a ceiling the encoder aims at, not a promise. Screen content
    /// usually lands far below it, which is the point of measuring.
    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw Failure("Could not create the H.264 encoder (status \(status)).")
        }

        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Main_AutoLevel
        )
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: fps * 2)
        )
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrate)
        )
        VTCompressionSessionPrepareToEncodeFrames(created)

        session = created
    }

    /// Returns immediately. The frame is encoded elsewhere, or dropped if the
    /// encoder has not caught up.
    func submit(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let accepted: Bool = lock.withLock {
            reading.submitted += 1
            guard inFlight < Self.maxInFlight else {
                reading.droppedBusy += 1
                return false
            }
            inFlight += 1
            return true
        }
        guard accepted else { return }

        let submittedAt = Date()
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }

            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: time,
                duration: .invalid,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { [weak self] status, _, sample in
                guard let self else { return }

                var size = 0
                var isKeyframe = false
                if status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) {
                    size = CMBlockBufferGetDataLength(block)
                    isKeyframe = Self.isKeyframe(sample)
                }

                self.lock.withLock {
                    self.inFlight -= 1
                    guard size > 0 else { return }
                    self.reading.frames += 1
                    self.reading.bytes += size
                    self.reading.largestFrame = max(self.reading.largestFrame, size)
                    self.reading.latencySeconds += Date().timeIntervalSince(submittedAt)
                    if isKeyframe { self.reading.keyframes += 1 }
                }
            }
        }
    }

    /// Waits for frames still inside the encoder, so the totals are not short.
    func finish() -> Reading {
        queue.sync {}
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        return lock.withLock { reading }
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]],
            let first = attachments.first
        else { return true }

        // The attachment says a frame *depends* on others; absent or false means
        // it stands alone, which is what a keyframe is.
        return !((first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool) ?? false)
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
