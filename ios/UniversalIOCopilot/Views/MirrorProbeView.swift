import SwiftUI

/// Scaffolding for the M4 transport measurement, not a product screen.
///
/// The Mac reports the numbers that matter — round trip, loss, throughput — so
/// this only has to show enough to tell a connected link from a silent one.
/// The most common failure is that nothing happens at all, which is why the
/// likely causes are on screen rather than in a log nobody will be holding.
struct MirrorProbeView: View {
    @State private var probe = MirrorProbe()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Mirror link probe")
                .font(.headline)

            switch probe.state {
            case .idle:
                Text("Start the Mac side first:")
                    .font(.callout)
                Text("./.build/debug/Broadcaster --link")
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("Look for the Mac") { probe.start() }
                    .buttonStyle(.borderedProminent)

            case .searching:
                ProgressView()
                Text(probe.disconnections > 0
                     ? "Lost the Mac and looking again — dropped \(probe.disconnections) time(s) so far."
                     : "Looking for a Mac advertising the mirror service…")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Text("""
                If this never finds anything, it is usually local network \
                permission rather than range. Check Settings › Privacy & \
                Security › Local Network for this app, and that the Mac side \
                is running.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            case .connected(let name):
                Label("Connected to \(name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(probe.received) payloads, \(probe.bytes / 1024) KB echoed")
                    .font(.callout.monospacedDigit())
                if probe.disconnections > 0 {
                    Text("reconnected after \(probe.disconnections) drop(s)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Read the result on the Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button("Done") {
                probe.stop()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .presentationDetents([.medium])
    }
}
