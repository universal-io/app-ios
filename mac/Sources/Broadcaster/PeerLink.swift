import Foundation
import MultipeerConnectivity

/// The Mac half of the wireless link, and the probe that measures it.
///
/// Measured with payloads the size of real frames rather than with real frames:
/// video is not involved, so a poor result belongs to the transport and cannot
/// be blamed on capture or encoding, both of which have already been measured
/// separately.
///
/// Timing is round-trip on purpose. One-way latency between two machines needs
/// their clocks reconciled, and a clock offset would sit inside every reading
/// with nothing to reveal it. The phone echoes the sequence number back, the Mac
/// times the loop, and one-way is taken as half — which is an assumption, but a
/// visible one.
final class PeerLink: NSObject {
    /// Must be 15 characters or fewer, lowercase letters, numbers and hyphens.
    /// The same string has to appear in the iOS app's NSBonjourServices or iOS
    /// refuses to browse without ever saying so.
    static let serviceType = "uio-mirror"

    /// A stall is more honest than a percentile on a small sample: the link is
    /// quick nearly always and occasionally stops, and counting the stops
    /// survives a short run where p95 is one unlucky payload.
    static let stallThreshold: TimeInterval = 0.2

    struct Reading {
        var sent = 0
        var bytesSent = 0
        var roundTrips: [Double] = []
        /// When each echo was sent, measured from the start of the run, paired
        /// with how long it took. Stalls arrive in clusters rather than spread
        /// out, and an average over the whole run hides that completely.
        var timeline: [(offset: Double, roundTrip: Double)] = []

        /// Sends the framework refused, which is not the same as a payload that
        /// went out and never came back. Swallowing these reported a peer that
        /// had left as 91% packet loss, and those two findings have opposite
        /// consequences.
        var sendFailures = 0
        /// Seconds into the run when the session dropped, if it did.
        var lostPeerAtSecond: Double?

        var echoed: Int { roundTrips.count }
        var lost: Int { sent - echoed }
        var lossPercent: Double { sent == 0 ? 0 : Double(lost) / Double(sent) * 100 }
        var stalls: Int { roundTrips.filter { $0 > PeerLink.stallThreshold }.count }

        /// True when nothing came back at all, which is a broken run rather than
        /// a lossy one and has to be reported differently — a previous sweep
        /// printed "100% lost, 0 ms" and it read like data.
        var isSilent: Bool { sent > 0 && roundTrips.isEmpty }

        func percentile(_ fraction: Double) -> Double {
            guard !roundTrips.isEmpty else { return 0 }
            let sorted = roundTrips.sorted()
            let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
            return sorted[index]
        }
    }

    private let peerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID,
        discoveryInfo: nil,
        serviceType: Self.serviceType
    )

    private let lock = NSLock()
    // Sequence numbers never restart and timings are never discarded between
    // runs. Clearing them was charging one rate for echoes that were still in
    // flight when the next rate started, which is how a sweep produced a row
    // that lost everything and a set of rows that got faster under more load.
    private var nextSequence: UInt32 = 0
    private var sentAt: [UInt32: Date] = [:]
    private var roundTrip: [UInt32: Double] = [:]
    private var connected: CheckedContinuation<MCPeerID, Error>?

    override init() {
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    /// Advertises until a phone joins. There is no pairing UI yet — the first
    /// peer to ask is accepted, which is fine on a desk and is not fine as a
    /// product (anyone nearby can see the advertisement; architecture section 2).
    func waitForPeer(timeout: TimeInterval) async throws -> MCPeerID {
        // Advertising stays on for the rest of the process. Stopping it once a
        // peer joined meant a phone that dropped out could never find the Mac
        // again, so a single disconnection ended the run while the sending loop
        // carried on talking to nobody.
        advertiser.startAdvertisingPeer()

        return try await withThrowingTaskGroup(of: MCPeerID.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.withLock { self.connected = continuation }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure("No phone joined within \(Int(timeout))s.")
            }

            let peer = try await group.next()!
            group.cancelAll()
            return peer
        }
    }

    /// Sends `count` payloads of `size` bytes, paced at `fps`, and waits briefly
    /// for the last echoes before reporting.
    ///
    /// Offering a fixed rate regardless of whether the link is keeping up is the
    /// point: the first run showed 15 ms at the median and 623 ms at p95 with
    /// nothing lost, which is a queue filling rather than a link failing. Only
    /// by pushing a rate and watching the spread does that become visible.
    func probe(count: Int, size: Int, fps: Int, reliable: Bool) async -> Reading {
        guard !session.connectedPeers.isEmpty else { return Reading() }

        let firstSequence = lock.withLock { nextSequence }
        let runStartedAt = Date()
        var sendFailures = 0
        var lostPeerAt: Double?

        // Random bytes rather than zeroes: a compressible payload would flatter
        // any transport that squeezes it on the way.
        var filler = Data(count: max(0, size - 4))
        filler.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, raw.count)
        }

        let interval = UInt64(1_000_000_000 / max(fps, 1))

        var bytesSent = 0

        for offset in 0..<UInt32(count) {
            // Read every time. Holding the list from before the loop meant a
            // phone that left was still being sent to, and the framework's
            // refusals were being discarded, so an empty room looked like a
            // congested one.
            let peers = session.connectedPeers
            if peers.isEmpty {
                if lostPeerAt == nil { lostPeerAt = Date().timeIntervalSince(runStartedAt) }
                try? await Task.sleep(nanoseconds: interval)
                continue
            }

            let sequence = firstSequence + offset
            var payload = Data()
            withUnsafeBytes(of: sequence.bigEndian) { payload.append(contentsOf: $0) }
            payload.append(filler)

            lock.withLock {
                sentAt[sequence] = Date()
                nextSequence = sequence + 1
            }
            bytesSent += payload.count

            // Stale video frames are meant to be dropped rather than queued, so
            // the measurement uses the same delivery mode the product will.
            do {
                try session.send(payload, toPeers: peers, with: reliable ? .reliable : .unreliable)
            } catch {
                sendFailures += 1
                if lostPeerAt == nil { lostPeerAt = Date().timeIntervalSince(runStartedAt) }
            }
            try? await Task.sleep(nanoseconds: interval)
        }

        // Long enough to outlast the worst stall seen so far, so a late echo is
        // counted rather than recorded as loss.
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        return lock.withLock {
            var reading = Reading()
            reading.sent = count
            reading.bytesSent = bytesSent
            reading.sendFailures = sendFailures
            reading.lostPeerAtSecond = lostPeerAt

            let range = firstSequence..<(firstSequence + UInt32(count))
            let runStart = sentAt[firstSequence] ?? Date()
            for sequence in range {
                guard let trip = roundTrip[sequence], let sent = sentAt[sequence] else { continue }
                reading.roundTrips.append(trip)
                reading.timeline.append((sent.timeIntervalSince(runStart), trip))
            }
            return reading
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

extension PeerLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // Printed as it happens rather than summarized at the end. A run that
        // ends with most payloads unaccounted for is a completely different
        // finding depending on whether the peer was there at the time, and the
        // timestamp is what tells them apart.
        switch state {
        case .notConnected:
            print("  [\(Self.clock())] \(peerID.displayName) disconnected")
        case .connecting:
            print("  [\(Self.clock())] \(peerID.displayName) connecting")
        case .connected:
            print("  [\(Self.clock())] \(peerID.displayName) connected")
        @unknown default:
            break
        }

        guard state == .connected else { return }
        let continuation = lock.withLock { () -> CheckedContinuation<MCPeerID, Error>? in
            defer { connected = nil }
            return connected
        }
        continuation?.resume(returning: peerID)
    }

    private static func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count >= 4 else { return }
        let sequence = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        lock.withLock {
            // Kept rather than removed, so a run can place each reading on a
            // timeline afterwards. Guarded against a duplicate echo counting
            // twice, which removal used to prevent as a side effect.
            guard let sent = sentAt[sequence], roundTrip[sequence] == nil else { return }
            roundTrip[sequence] = Date().timeIntervalSince(sent)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PeerLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        invitationHandler(true, session)
    }
}
