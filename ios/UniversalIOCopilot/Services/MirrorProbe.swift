import Foundation
import MultipeerConnectivity
import UIKit

/// The phone's half of the link measurement: find the Mac, join it, and echo
/// back the sequence number of everything it sends.
///
/// Deliberately not the mirror. Nothing here decodes or displays anything, so
/// whatever the Mac reports is the transport's own latency and loss — capture
/// and encoding were measured separately and cannot be blamed for the result.
/// The connection handling is the part worth keeping; the echoing is not.
@MainActor
@Observable
final class MirrorProbe: NSObject {
    enum State: Equatable {
        case idle
        case searching
        case connected(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var received = 0
    private(set) var bytes = 0

    private let peerID = MCPeerID(displayName: UIDevice.current.name)
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
        super.init()
        session.delegate = self
        browser.delegate = self
    }

    func start() {
        guard state == .idle else { return }
        received = 0
        bytes = 0
        state = .searching
        // A sweep runs for minutes without anyone touching the phone. If the
        // screen sleeps mid-run the app stops echoing and that rate reports
        // total loss — which is indistinguishable in the results from a link
        // that failed, and a previous sweep produced exactly that row.
        UIApplication.shared.isIdleTimerDisabled = true
        browser.startBrowsingForPeers()
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        browser.stopBrowsingForPeers()
        session.disconnect()
        state = .idle
    }
}

/// The one string both sides have to agree on, including the app's
/// NSBonjourServices entries.
enum PeerService {
    static let type = "uio-mirror"
}

extension MirrorProbe: @preconcurrency MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.state = .connected(peerID.displayName)
                self.browser.stopBrowsingForPeers()
            case .notConnected:
                if case .connected = self.state { self.state = .searching }
                self.browser.startBrowsingForPeers()
            default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count >= 4 else { return }

        // Echo only the sequence number. Sending the payload back would measure
        // a round trip of twice the size and report it as if it were one.
        let sequence = data.prefix(4)
        try? session.send(sequence, toPeers: [peerID], with: .reliable)

        let size = data.count
        Task { @MainActor in
            self.received += 1
            self.bytes += size
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MirrorProbe: @preconcurrency MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Joining the first Mac that appears is only acceptable because this is a
        // measurement on a desk. Multipeer shows every nearby device running the
        // same service, so the product needs pairing before this ships.
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            // Almost always the missing NSBonjourServices entry or a refused
            // local network permission, neither of which says so plainly.
            self.state = .failed(error.localizedDescription)
        }
    }
}
