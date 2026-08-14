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
/// Configured for live use rather than for the smallest file — no frame
/// reordering, so nothing waits on a later frame to be decodable, which is
/// latency the viewer would feel and never see a reason for.
final class FrameEncoder {
    struct Reading {
        var frames = 0
        var keyframes = 0
        var bytes = 0
        var largestFrame = 0
        var encodeSeconds: Double = 0

        var meanBytes: Int { frames == 0 ? 0 : bytes / frames }
        func megabitsPerSecond(over seconds: Double) -> Double {
            seconds <= 0 ? 0 : Double(bytes) * 8 / seconds / 1_000_000
        }
    }

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var reading = Reading()

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

    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let session else { return }
        let started = Date()

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else {
                return
            }

            let size = CMBlockBufferGetDataLength(block)
            let isKeyframe = Self.isKeyframe(sample)

            self.lock.withLock {
                self.reading.frames += 1
                self.reading.bytes += size
                self.reading.largestFrame = max(self.reading.largestFrame, size)
                self.reading.encodeSeconds += Date().timeIntervalSince(started)
                if isKeyframe { self.reading.keyframes += 1 }
            }
        }
    }

    /// Waits for frames still inside the encoder, so the totals are not short.
    func finish() -> Reading {
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
