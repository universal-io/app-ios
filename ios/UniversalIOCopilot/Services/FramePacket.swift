import Foundation

/// One frame on the wire, as the Mac companion writes it.
///
/// The layout is duplicated from `mac/Sources/Broadcaster/FramePacket.swift`
/// rather than shared, because the two projects deliberately do not depend on
/// each other (README). It is small enough to keep in step by hand, and the
/// version byte turns a mismatch into a refusal instead of a picture made of
/// garbage.
enum FramePacket {
    static let version: UInt8 = 1

    struct Frame {
        var isKeyframe: Bool
        /// Milliseconds since the broadcast began. Used to recognize a frame
        /// that arrived behind a stall, so the viewer can skip to the present
        /// rather than work through a backlog.
        var elapsedMilliseconds: UInt64
        /// Present on keyframes. A decoder cannot read anything without them.
        var parameterSets: [Data]
        var data: Data
    }

    static func decode(_ packet: Data) -> Frame? {
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
            isKeyframe: keyframe == 1,
            elapsedMilliseconds: elapsed,
            parameterSets: parameterSets,
            data: Data(frame)
        )
    }
}
