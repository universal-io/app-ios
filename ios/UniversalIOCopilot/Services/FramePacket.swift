import Foundation

/// What travels between the Mac and the phone.
///
/// Three shapes, told apart by a type byte: a frame coming in, an
/// acknowledgement going back, and a request for a fresh keyframe. The last two
/// exist because of what the first attempt at mirroring did on a real screen —
/// it fell apart into garbage that never healed, and it stuttered.
///
/// The layout is duplicated from `mac/Sources/Broadcaster/FramePacket.swift`
/// rather than shared, because the two projects deliberately do not depend on
/// each other (README). It is small enough to keep in step by hand, and the
/// version byte turns a mismatch into a refusal instead of a picture made of
/// noise.
enum FramePacket {
    static let version: UInt8 = 2

    enum Kind: UInt8 {
        case frame = 1
        case ack = 2
        case keyframeRequest = 3
    }

    struct Frame {
        /// Numbered so a missing one can be noticed. Unreliable delivery means a
        /// frame can vanish, and a decoder handed the next one carries on
        /// against a reference it no longer has — which it does not report as an
        /// error, it just produces a picture that steadily becomes wrong.
        var sequence: UInt32
        var isKeyframe: Bool
        /// Milliseconds since the broadcast began, used to recognize a frame
        /// that arrived behind a stall so the viewer can stay current.
        var elapsedMilliseconds: UInt64
        /// Present on keyframes. A decoder cannot read anything without them.
        var parameterSets: [Data]
        var data: Data
    }

    static func decodeFrame(_ packet: Data) -> Frame? {
        let bytes = [UInt8](packet)
        var offset = 0

        func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }
        func number<T: FixedWidthInteger>(_ slice: ArraySlice<UInt8>?, as: T.Type) -> T? {
            guard let slice else { return nil }
            return slice.reduce(T(0)) { ($0 << 8) | T($1) }
        }

        guard let marker = take(1)?.first, marker == version else { return nil }
        guard let kind = take(1)?.first, kind == Kind.frame.rawValue else { return nil }
        guard let sequence = number(take(4), as: UInt32.self) else { return nil }
        guard let keyframe = take(1)?.first else { return nil }
        guard let elapsed = number(take(8), as: UInt64.self) else { return nil }

        guard let setCount = take(1)?.first else { return nil }
        var parameterSets: [Data] = []
        for _ in 0..<setCount {
            guard let length = number(take(2), as: UInt16.self),
                  let set = take(Int(length))
            else { return nil }
            parameterSets.append(Data(set))
        }

        guard let length = number(take(4), as: UInt32.self),
              let frame = take(Int(length))
        else { return nil }

        return Frame(
            sequence: sequence,
            isKeyframe: keyframe == 1,
            elapsedMilliseconds: elapsed,
            parameterSets: parameterSets,
            data: Data(frame)
        )
    }

    /// Frees a slot on the sender, which will not send more than a few frames
    /// beyond what has been acknowledged.
    static func encodeAck(sequence: UInt32) -> Data {
        var packet = Data([version, Kind.ack.rawValue])
        withUnsafeBytes(of: sequence.bigEndian) { packet.append(contentsOf: $0) }
        return packet
    }

    /// Asks for a keyframe now rather than at the next scheduled one, which may
    /// be two seconds of wrong picture away.
    static func encodeKeyframeRequest() -> Data {
        Data([version, Kind.keyframeRequest.rawValue])
    }
}
