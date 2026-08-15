import AVFoundation
import SwiftUI

/// The Mac's screen, on the phone.
///
/// Laid out the way M1 concluded the product should be: the picture takes the
/// whole screen and everything else floats over it. A mirrored Mac screen is
/// wider than anything the camera produces, so splitting the screen in two
/// leaves text too small to read — which was already true of camera mode in
/// landscape (roadmap M1, "レイアウトの方針").
struct MirrorView: View {
    @State private var receiver = MirrorReceiver()
    @State private var session = AnalysisSession()
    @State private var explainedSize: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                ZStack {
                    MirrorSurface(layer: receiver.displayLayer)

                    // Drawn against the frame that was explained, not the one on
                    // screen now. The picture keeps moving while the answer is
                    // being written, and a highlight that follows it would drift
                    // off whatever it was pointing at.
                    if let result = session.result, explainedSize != .zero {
                        AnnotationOverlay(annotations: result.annotations, imageSize: explainedSize)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { point in explain(tappedAt: point, in: proxy.size) }
            }
            .ignoresSafeArea()

            if case .connected = receiver.state {} else {
                waitingPanel
            }

            VStack {
                statusBar
                Spacer()
                if session.phase != .framing { answerPanel }
            }
        }
        .task {
            session.sourceKind = "mirror"
            receiver.start()
        }
        .onDisappear { receiver.stop() }
    }

    /// Explains whatever is on screen, about the place that was touched.
    ///
    /// The whole analysis path is the one camera mode already proved — same
    /// server, same normalized coordinates, same overlay — so mirroring only
    /// had to supply a different picture.
    private func explain(tappedAt point: CGPoint, in viewSize: CGSize) {
        guard let frame = receiver.currentFrame() else { return }

        let geometry = OverlayGeometry(imageSize: frame.size, viewSize: viewSize)
        explainedSize = frame.size
        session.reset()
        session.analyze(imageData: frame.jpeg, tapPoint: geometry.normalizedPoint(fromViewPoint: point))
    }

    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let reason) = session.phase {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if session.isBusy && session.streamingText.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Reading the screen…").font(.callout)
                }
            } else {
                ScrollView {
                    Text(session.streamingText)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            HStack {
                Text("Tap the screen to ask again")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { session.reset() }
                    .font(.caption)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(12)
        .foregroundStyle(.white)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button {
                receiver.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
            }

            if case .connected(let name) = receiver.state {
                Text(name).font(.caption.weight(.semibold))
                Text("\(Int(receiver.frameSize.width))×\(Int(receiver.frameSize.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(receiver.framesShown) frames")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Skips and drops are the two things the M4 measurements said would
            // happen, so they are on screen rather than in a log: a mirror that
            // is quietly discarding half the stream should look different from
            // one that is not.
            if receiver.framesSkipped > 0 {
                Text("\(receiver.framesSkipped) skipped")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
            if receiver.gapsRecovered > 0 {
                Text("\(receiver.gapsRecovered) gaps")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
            if receiver.disconnections > 0 {
                Text("\(receiver.disconnections) drops")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
    }

    private var waitingPanel: some View {
        VStack(spacing: 14) {
            switch receiver.state {
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            default:
                ProgressView().tint(.white)
                Text(receiver.disconnections > 0
                     ? "Lost the Mac — looking again."
                     : "Looking for a Mac sharing its screen…")
                    .font(.callout)
                Text("./.build/debug/Broadcaster --mirror")
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text("""
                If nothing is found, it is usually local network permission \
                rather than range — Settings › Privacy & Security › Local Network.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .padding(28)
    }
}

/// Hosts the layer the receiver is already feeding. The layer is not created
/// here, because frames arrive from the network whether or not a view exists.
private struct MirrorSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.backgroundColor = .black
        view.attach(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class HostView: UIView {
        private weak var hosted: AVSampleBufferDisplayLayer?

        func attach(_ incoming: AVSampleBufferDisplayLayer) {
            hosted?.removeFromSuperlayer()
            layer.addSublayer(incoming)
            hosted = incoming
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // No implicit animation: the layer would slide into place on every
            // rotation and drag the picture with it.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
