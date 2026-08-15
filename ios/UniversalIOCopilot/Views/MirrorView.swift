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
    /// How often the copilot looks at the screen by itself.
    ///
    /// The point of watching a mirror is that it is live, and having to ask
    /// after every change breaks that. Ten seconds is a starting value, not a
    /// measured one: often enough to feel like it is keeping up, rare enough
    /// that a session does not turn into a stream of requests.
    private static let autoInterval: Duration = .seconds(10)

    @State private var receiver = MirrorReceiver()
    @State private var session = AnalysisSession()
    @State private var explainedSize: CGSize = .zero
    @State private var autoExplain = true
    @State private var autoTask: Task<Void, Never>?
    @State private var tappedOutside = false
    @State private var panelExpanded = false
    /// Counts analyses so two answers about the same thing are still visibly
    /// different requests, and shows when a tap produced no request at all.
    @State private var analysisCount = 0
    @State private var frameUnavailable = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                ZStack {
                    MirrorSurface(layer: receiver.displayLayer)

                    // Drawn against the frame that was explained, not the one on
                    // screen now. The picture keeps moving while the answer is
                    // being written, and a highlight tied to the live image
                    // would drift off whatever it was pointing at.
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
                if tappedOutside { outsideHint }
                if frameUnavailable { frameHint }
                if session.phase != .framing { answerPanel }
            }
        }
        .task {
            session.sourceKind = "mirror"
            receiver.start()
            startAutoExplaining()
        }
        .onDisappear {
            autoTask?.cancel()
            receiver.stop()
        }
    }

    // MARK: - Explaining

    /// Explains the place that was touched.
    ///
    /// A mirrored Mac screen is far wider than a phone held upright, so most of
    /// this view is letterbox rather than picture — on an iPhone 13 in portrait
    /// the image is about a third of the height. A touch on the black bars has
    /// no position in the image, and sending the request anyway silently drops
    /// the tap point and takes the prompt's "no question, no tap" branch, which
    /// describes the whole screen. That is what made it look stuck: every touch
    /// outside the picture produced the same general answer.
    private func explain(tappedAt point: CGPoint, in viewSize: CGSize) {
        guard let frame = receiver.currentFrame() else {
            // Returning quietly here is what made repeated taps look like a
            // stuck answer: nothing was sent, and the previous explanation
            // stayed on screen looking like a fresh reply about the wrong
            // thing. A failure has to be visible to be diagnosable.
            withAnimation { frameUnavailable = true }
            return
        }
        withAnimation { frameUnavailable = false }

        let geometry = OverlayGeometry(imageSize: frame.size, viewSize: viewSize)
        guard let normalized = geometry.normalizedPoint(fromViewPoint: point) else {
            withAnimation { tappedOutside = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { tappedOutside = false }
            }
            return
        }

        run(frame: frame, tapPoint: normalized)
    }

    /// Explains the screen as a whole, which is what the automatic pass does.
    private func explainEverything() {
        guard let frame = receiver.currentFrame() else { return }
        run(frame: frame, tapPoint: nil)
    }

    private func run(frame: (jpeg: Data, size: CGSize), tapPoint: CGPoint?) {
        explainedSize = frame.size
        analysisCount += 1
        session.reset()
        session.analyze(imageData: frame.jpeg, tapPoint: tapPoint)
    }

    private func startAutoExplaining() {
        autoTask?.cancel()
        autoTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoInterval)
                guard !Task.isCancelled, autoExplain, !session.isBusy else { continue }
                guard case .connected = receiver.state else { continue }
                explainEverything()
            }
        }
    }

    // MARK: - Chrome

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button {
                autoTask?.cancel()
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
            }

            // Skips and gaps are the two things the M4 measurements said would
            // happen, so they are on screen rather than in a log: a mirror
            // quietly shedding frames should not look like one that is not.
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

            Button {
                autoExplain.toggle()
            } label: {
                Label("Auto", systemImage: autoExplain ? "eye.fill" : "eye.slash")
                    .font(.caption.weight(.semibold))
            }
            .tint(autoExplain ? .green : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
    }

    private var outsideHint: some View {
        Text("That is outside the screen — tap on the picture itself")
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
            .transition(.opacity)
    }

    private var frameHint: some View {
        Text("Could not read the current frame — nothing was sent")
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.orange)
            .transition(.opacity)
    }

    /// Deliberately small. It sits over the picture it is describing, and the
    /// first version covered most of the screen — an explanation that hides
    /// what it is explaining is worse than a short one.
    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The picture that was actually analyzed, next to its answer.
            // Repeated taps returning the first screen's explanation is either
            // a stale frame or a request that never went out, and those need
            // opposite fixes — showing what was sent tells them apart without
            // guessing, which this problem has already cost twice.
            HStack(spacing: 8) {
                if let analyzed = session.capturedImage {
                    Image(uiImage: analyzed)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.3)))
                }
                Text("#\(analysisCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if case .failed(let reason) = session.phase {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if session.isBusy && session.streamingText.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(.white).controlSize(.small)
                    Text("Reading the screen…").font(.caption)
                }
            } else {
                ScrollView {
                    Text(session.streamingText)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: panelExpanded ? 220 : 68)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .foregroundStyle(.white)
        // Tapping the answer grows it, rather than it always taking the room a
        // long answer might need.
        .onTapGesture { withAnimation { panelExpanded.toggle() } }
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
