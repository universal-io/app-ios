import Foundation

/// One frame on the wire.
///
/// Every packet stands on its own. A keyframe carries the parameter sets a
/// decoder needs, so a viewer that joins late, or comes back after the link
/// stalls for a few seconds, starts decoding at the next keyframe rather than
/// waiting for a handshake it already missed. Measured 2026-08-15: the link
/// does stall, occasionally for hundreds of milliseconds, so recovering
/// without a round trip is worth the repetition.
///
/// The layout is duplicated in the iOS app rather than shared through a
/// package, because the two projects deliberately do not depend on each other.
/// It is small, and it is versioned so a mismatch is caught rather than
/// decoded into nonsense.
enum FramePacket {
    static let version: UInt8 = 1

    /// Milliseconds since the broadcast began. The viewer uses it to tell a
    /// fresh frame from one that arrived behind a stall.
    static func encode(frame: Data, isKeyframe: Bool, parameterSets: [Data], elapsedMilliseconds: UInt64) -> Data {
        var packet = Data()
        packet.append(version)
        packet.append(isKeyframe ? 1 : 0)
        withUnsafeBytes(of: elapsedMilliseconds.bigEndian) { packet.append(contentsOf: $0) }

        packet.append(UInt8(min(parameterSets.count, 255)))
        for set in parameterSets.prefix(255) {
            withUnsafeBytes(of: UInt16(set.count).bigEndian) { packet.append(contentsOf: $0) }
            packet.append(set)
        }

        withUnsafeBytes(of: UInt32(frame.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(frame)
        return packet
    }
}
