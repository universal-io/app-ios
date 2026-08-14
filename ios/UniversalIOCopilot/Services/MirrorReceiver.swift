@preconcurrency import AVFoundation
import Foundation
import MultipeerConnectivity
import UIKit

/// Turns received packets into pictures, off the main actor.
///
/// Separate from the receiver because frames arrive on Multipeer's own queue and
/// the renderer is documented as safe to feed from a background thread. Left
/// inside a `@MainActor` type, every frame would have to hop twice for no reason
/// and the decode state could not be touched where it is used.
///
/// Unchecked because `AVSampleBufferVideoRenderer` carries no `Sendable`
/// promise of its own; the guarantee comes from Apple's header, and everything
/// else here is behind the lock.
final class MirrorDecoder: @unchecked Sendable {
    struct Outcome {
        var shown = false
        var size: CGSize = .zero
        /// The sequence to acknowledge, so the sender can free a slot.
        var acknowledge: UInt32?
        /// Set when a frame went missing. Decoding onward from a gap does not
        /// fail — it produces a picture that is quietly, increasingly wrong —
        /// so the only way out is a keyframe, and waiting for the scheduled one
        /// means up to two seconds of that.
        var needsKeyframe = false
    }

    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var newestFrameMilliseconds: UInt64 = 0
    private var expectedSequence: UInt32?
    private var awaitingKeyframe = false

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    /// Starts over: no format, no history. The picture stops being true the
    /// moment the link goes, and the decoder has to begin again at a keyframe.
    func reset() {
        lock.withLock {
            format = nil
            newestFrameMilliseconds = 0
            expectedSequence = nil
            awaitingKeyframe = false
        }
        renderer.flush()
    }

    func present(_ packet: Data) -> Outcome {
        guard let frame = FramePacket.decodeFrame(packet) else { return Outcome() }

        var outcome = Outcome()
        outcome.acknowledge = frame.sequence

        let prepared: (CMSampleBuffer, CGSize)? = lock.withLock {
            // A frame older than one already shown got here behind a stall.
            // Showing it would rewind the picture, and the point of a mirror is
            // to be current, so it goes in the bin.
            guard frame.elapsedMilliseconds >= newestFrameMilliseconds else { return nil }

            // A gap means some frame this one is built on never arrived. The
            // decoder will not object; it will just draw the difference onto a
            // picture that is already wrong, and keep doing so. Hold the last
            // good image until a keyframe arrives instead.
            if let expected = expectedSequence, frame.sequence != expected, !frame.isKeyframe {
                awaitingKeyframe = true
                outcome.needsKeyframe = true
            }
            expectedSequence = frame.sequence &+ 1

            if !frame.parameterSets.isEmpty {
                format = Self.makeFormat(frame.parameterSets) ?? format
            }
            guard let format else { return nil }

            // After a decode failure nothing plays until the renderer is
            // flushed, and the first frame afterwards has to stand alone.
            if renderer.requiresFlushToResumeDecoding {
                renderer.flush()
                awaitingKeyframe = true
                outcome.needsKeyframe = true
            }

            if awaitingKeyframe {
                guard frame.isKeyframe else { return nil }
                awaitingKeyframe = false
            }

            guard let sample = Self.makeSample(frame.data, format: format) else { return nil }
            newestFrameMilliseconds = frame.elapsedMilliseconds

            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            return (sample, CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
        }

        guard let prepared else { return outcome }
        renderer.enqueue(prepared.0)
        outcome.shown = true
        outcome.size = prepared.1
        return outcome
    }

    /// Builds the description of how to read everything that follows, out of the
    /// sequence and picture parameter sets the sender attaches to keyframes.
    private static func makeFormat(_ sets: [Data]) -> CMVideoFormatDescription? {
        guard sets.count >= 2 else { return nil }

        return sets[0].withUnsafeBytes { sps -> CMVideoFormatDescription? in
            sets[1].withUnsafeBytes { pps -> CMVideoFormatDescription? in
                guard
                    let spsBase = sps.bindMemory(to: UInt8.self).baseAddress,
                    let ppsBase = pps.bindMemory(to: UInt8.self).baseAddress
                else { return nil }

                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                var format: CMVideoFormatDescription?

                let status = pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            // VideoToolbox writes AVCC, where every unit is
                            // prefixed with a four byte length.
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
                return status == noErr ? format : nil
            }
        }
    }

    /// Wraps the compressed bytes in a sample the renderer accepts, marked to
    /// show as soon as it decodes. No timebase: the header warns against
    /// combining one with display-immediately, and a mirror has no timeline to
    /// synchronize to — the newest frame is always the right one.
    private static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var sizes = [data.count]
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                entry,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sample
    }
}

/// Finds the Mac, joins it, and hands what arrives to the decoder.
///
/// Two behaviors come out of the M4 measurements rather than from preference:
/// frames arriving behind a stall are discarded instead of shown, and a decoder
/// that has given up is restarted at the next keyframe — which the sender
/// provides every couple of seconds with its parameter sets attached.
@MainActor
@Observable
final class MirrorReceiver: NSObject {
    enum State: Equatable {
        case idle
        case searching
        case connected(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var framesShown = 0
    private(set) var framesSkipped = 0
    private(set) var disconnections = 0
    private(set) var gapsRecovered = 0
    private(set) var frameSize: CGSize = .zero

    /// Owned here, not by the view: frames arrive from the network whether or
    /// not anything is on screen to receive them.
    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private let decoder: MirrorDecoder

    @ObservationIgnored private let peerID = MCPeerID(displayName: UIDevice.current.name)
    @ObservationIgnored private lazy var session = MCSession(
        peer: peerID,
        securityIdentity: nil,
        encryptionPreference: .required
    )
    @ObservationIgnored private lazy var browser = MCNearbyServiceBrowser(
        peer: peerID,
        serviceType: PeerService.type
    )

    override init() {
        decoder = MirrorDecoder(renderer: displayLayer.sampleBufferRenderer)
        super.init()
        session.delegate = self
        browser.delegate = self
        displayLayer.videoGravity = .resizeAspect
    }

    func start() {
        guard state == .idle else { return }
        framesShown = 0
        framesSkipped = 0
        disconnections = 0
        gapsRecovered = 0
        state = .searching
        // Mirroring is watched, not touched. Without this the screen dims part
        // way through and the link dies for a reason nobody would guess.
        UIApplication.shared.isIdleTimerDisabled = true
        browser.startBrowsingForPeers()
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        browser.stopBrowsingForPeers()
        session.disconnect()
        decoder.reset()
        state = .idle
    }
}

extension MirrorReceiver: @preconcurrency MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.state = .connected(peerID.displayName)
                self.browser.stopBrowsingForPeers()
            case .notConnected:
                if case .connected = self.state {
                    self.disconnections += 1
                    self.state = .searching
                }
                self.decoder.reset()
                self.browser.startBrowsingForPeers()
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let outcome = decoder.present(data)

        // Replies go out reliably and are a handful of bytes. Losing one costs
        // the sender a slot until the next acknowledgement, and losing a
        // keyframe request costs up to two seconds of wrong picture.
        if let sequence = outcome.acknowledge {
            try? session.send(FramePacket.encodeAck(sequence: sequence), toPeers: [peerID], with: .reliable)
        }
        if outcome.needsKeyframe {
            try? session.send(FramePacket.encodeKeyframeRequest(), toPeers: [peerID], with: .reliable)
        }

        Task { @MainActor in
            if outcome.shown {
                self.framesShown += 1
                self.frameSize = outcome.size
            } else {
                self.framesSkipped += 1
            }
            if outcome.needsKeyframe { self.gapsRecovered += 1 }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MirrorReceiver: @preconcurrency MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Joining whatever appears is a measurement shortcut, not a design.
        // Multipeer shows every nearby device running this service, so pairing
        // has to exist before anyone but us runs it (architecture section 2).
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
        }
    }
}
