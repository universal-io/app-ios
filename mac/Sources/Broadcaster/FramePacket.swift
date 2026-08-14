import Foundation

/// What travels between the Mac and the phone.
///
/// Three shapes, told apart by a type byte: a frame going out, an
/// acknowledgement coming back, and a request for a fresh keyframe. The last
/// two exist because of what the first attempt at mirroring did on a real
/// screen — it fell apart into garbage that never healed, and it stuttered.
///
/// The layout is duplicated in the iOS app rather than shared, because the two
/// projects deliberately do not depend on each other (README). The version byte
/// turns a mismatch into a refusal instead of a picture made of noise.
enum FramePacket {
    static let version: UInt8 = 2

    enum Kind: UInt8 {
        case frame = 1
        case ack = 2
        case keyframeRequest = 3
    }

    /// Frames are numbered so the viewer can notice one missing. Unreliable
    /// delivery means a frame can vanish, and a decoder handed the next one
    /// carries on against a reference it no longer has — which is not an error
    /// it reports, just a picture that slowly becomes wrong.
    static func encodeFrame(
        sequence: UInt32,
        frame: Data,
        isKeyframe: Bool,
        parameterSets: [Data],
        elapsedMilliseconds: UInt64
    ) -> Data {
        var packet = Data()
        packet.append(version)
        packet.append(Kind.frame.rawValue)
        withUnsafeBytes(of: sequence.bigEndian) { packet.append(contentsOf: $0) }
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

    struct Control {
        var kind: Kind
        var sequence: UInt32
    }

    static func decodeControl(_ packet: Data) -> Control? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 2, bytes[0] == version, let kind = Kind(rawValue: bytes[1]) else { return nil }

        switch kind {
        case .ack:
            guard bytes.count >= 6 else { return nil }
            let sequence = bytes[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Control(kind: .ack, sequence: sequence)
        case .keyframeRequest:
            return Control(kind: .keyframeRequest, sequence: 0)
        case .frame:
            return nil
        }
    }
}
