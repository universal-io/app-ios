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

    struct Reading {
        var sent = 0
        var echoed = 0
        var bytesSent = 0
        var roundTrips: [Double] = []

        var lost: Int { sent - echoed }
        var lossPercent: Double { sent == 0 ? 0 : Double(lost) / Double(sent) * 100 }

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
    private var reading = Reading()
    private var sentAt: [UInt32: Date] = [:]
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
        advertiser.startAdvertisingPeer()
        defer { advertiser.stopAdvertisingPeer() }

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
        lock.withLock {
            reading = Reading()
            sentAt.removeAll()
        }

        let peers = session.connectedPeers
        guard !peers.isEmpty else { return lock.withLock { reading } }

        // Random bytes rather than zeroes: a compressible payload would flatter
        // any transport that squeezes it on the way.
        var filler = Data(count: max(0, size - 4))
        filler.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, raw.count)
        }

        let interval = UInt64(1_000_000_000 / max(fps, 1))

        for sequence in 0..<UInt32(count) {
            var payload = Data()
            withUnsafeBytes(of: sequence.bigEndian) { payload.append(contentsOf: $0) }
            payload.append(filler)

            lock.withLock {
                sentAt[sequence] = Date()
                reading.sent += 1
                reading.bytesSent += payload.count
            }

            // Stale video frames are meant to be dropped rather than queued, so
            // the measurement uses the same delivery mode the product will.
            try? session.send(payload, toPeers: peers, with: reliable ? .reliable : .unreliable)
            try? await Task.sleep(nanoseconds: interval)
        }

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return lock.withLock { reading }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

extension PeerLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .connected else { return }
        let continuation = lock.withLock { () -> CheckedContinuation<MCPeerID, Error>? in
            defer { connected = nil }
            return connected
        }
        continuation?.resume(returning: peerID)
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count >= 4 else { return }
        let sequence = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        lock.withLock {
            guard let sent = sentAt.removeValue(forKey: sequence) else { return }
            reading.echoed += 1
            reading.roundTrips.append(Date().timeIntervalSince(sent))
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
