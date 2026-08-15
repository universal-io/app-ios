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
    /// How often the copilot looks at the screen by itself, once asked to.
    ///
    /// The point of watching a mirror is that it is live, and having to ask
    /// after every change breaks that. Ten seconds is a starting value, not a
    /// measured one: often enough to feel like it is keeping up, rare enough
    /// that a session does not turn into a stream of requests.
    private static let autoInterval: Duration = .seconds(10)

    @State private var receiver = MirrorReceiver()
    @State private var session = AnalysisSession()
    @State private var explainedSize: CGSize = .zero
    /// Off until asked for, and off again the moment the person touches
    /// something. An automatic pass replaces the answer on screen with one
    /// about the whole screen, which arrives while they are still reading the
    /// answer they asked for — it reads as the copilot explaining the wrong
    /// thing, and there is no way to tell the two apart after the fact.
    @State private var autoExplain = false
    @State private var autoTask: Task<Void, Never>?
    @State private var tappedOutside = false
    @State private var panelExpanded = false
    /// Counts analyses so two answers about the same thing are still visibly
    /// different requests, and shows when a tap produced no request at all.
    @State private var analysisCount = 0
    @State private var frameUnavailable = false
    /// Where the last request said the person touched, in image coordinates.
    /// An answer about a neighbour of the thing they touched has two possible
    /// causes — the point arrived somewhere else, or the model chose the wrong
    /// element — and they need opposite fixes. Drawing the point that was sent
    /// beside the box that came back tells them apart by looking.
    @State private var tapMark: CGPoint?
    /// The ring being drawn right now, in view points, and the one the current
    /// answer belongs to, in image coordinates. Two spaces because the first is
    /// gone the moment the finger lifts, while the second has to survive the
    /// picture moving underneath it.
    @State private var strokeInProgress: [CGPoint] = []
    @State private var ringMark: [CGPoint]?
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

                    selectionMarks(in: proxy.size)
                }
                .contentShape(Rectangle())
                // One gesture for both ways of pointing: a touch that stays put
                // is a tap, and one that travels is a ring drawn around
                // something. Separating them by distance rather than by a mode
                // switch keeps the screen free of controls to learn.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in strokeInProgress.append(value.location) }
                        .onEnded { value in
                            let stroke = strokeInProgress.isEmpty ? [value.location] : strokeInProgress
                            strokeInProgress = []
                            explain(stroke: stroke, in: proxy.size)
                        }
                )
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

    /// How far a finger has to travel before it counts as drawing a ring rather
    /// than pointing at something. Small enough that deliberate circling always
    /// registers, large enough that a tap with an unsteady hand does not.
    private static let ringThreshold: CGFloat = 24

    /// Decides which of the two questions the finger asked, then answers it.
    private func explain(stroke: [CGPoint], in viewSize: CGSize) {
        // A touch is someone taking over, so the automatic pass stops for the
        // rest of the session rather than overwriting their answer ten seconds
        // later. It can be turned back on from the status bar.
        autoExplain = false

        let bounds = Self.bounds(of: stroke)
        if max(bounds.width, bounds.height) < Self.ringThreshold {
            explain(tappedAt: stroke[0], in: viewSize)
        } else {
            explain(ring: stroke, bounds: bounds, in: viewSize)
        }
    }

    /// Explains whatever the ring encloses.
    ///
    /// The request carries the box around the stroke rather than its outline:
    /// the model reasons about rectangles everywhere else in this protocol, and
    /// a hand-drawn loop is a rectangle's worth of intent anyway. The drawn
    /// shape stays on screen because that is what the person will remember
    /// asking about.
    private func explain(ring stroke: [CGPoint], bounds: CGRect, in viewSize: CGSize) {
        guard let frame = receiver.currentFrame() else {
            withAnimation { frameUnavailable = true }
            return
        }
        withAnimation { frameUnavailable = false }

        let geometry = OverlayGeometry(imageSize: frame.size, viewSize: viewSize)
        guard let region = geometry.normalizedRect(fromViewRect: bounds) else {
            showOutsideHint()
            return
        }

        ringMark = stroke.map { geometry.clampedNormalizedPoint(fromViewPoint: $0) }
        run(frame: frame, tapPoint: nil, region: region)
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }

        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            rect = rect.union(CGRect(origin: point, size: .zero))
        }
        return rect
    }

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
            showOutsideHint()
            return
        }

        run(frame: frame, tapPoint: normalized)
    }

    /// Explains the screen as a whole, which is what the automatic pass does.
    private func explainEverything() {
        guard let frame = receiver.currentFrame() else { return }
        run(frame: frame, tapPoint: nil)
    }

    private func showOutsideHint() {
        withAnimation { tappedOutside = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { tappedOutside = false }
        }
    }

    private func run(frame: (jpeg: Data, size: CGSize), tapPoint: CGPoint?, region: CGRect? = nil) {
        explainedSize = frame.size
        analysisCount += 1
        tapMark = tapPoint
        if region == nil { ringMark = nil }
        session.reset()
        session.analyze(imageData: frame.jpeg, tapPoint: tapPoint, region: region)
    }

    /// What was asked, drawn on top of what it was asked about.
    ///
    /// Everything here goes back through the same conversion that produced the
    /// request, so a mark under the finger means the coordinates left correctly
    /// and a box somewhere else is the model's own choice. Drawn any other way
    /// it would prove nothing about the transform it is there to check.
    @ViewBuilder
    private func selectionMarks(in viewSize: CGSize) -> some View {
        // The line following the finger, before there is anything to send.
        if strokeInProgress.count > 1 {
            Path { path in path.addLines(strokeInProgress) }
                .stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
        }

        if explainedSize != .zero {
            let geometry = OverlayGeometry(imageSize: explainedSize, viewSize: viewSize)

            if let ringMark, ringMark.count > 1 {
                Path { path in
                    path.addLines(ringMark.map { geometry.viewPoint(forNormalized: $0) })
                    path.closeSubpath()
                }
                .stroke(.cyan.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
            }

            if let tapMark {
                ZStack {
                    Circle().stroke(.cyan, lineWidth: 2).frame(width: 26, height: 26)
                    Circle().fill(.cyan).frame(width: 4, height: 4)
                }
                .position(geometry.viewPoint(forNormalized: tapMark))
                .allowsHitTesting(false)
            }
        }
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

    /// Deliberately small, and no larger than what it has to say. It sits over
    /// the picture it is describing, so every point of it that is not text is
    /// hiding something the person is trying to look at — a fixed-size panel
    /// left a band of empty material down the right and along the bottom of
    /// every short answer.
    private var answerPanel: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("#\(analysisCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                if case .failed(let reason) = session.phase {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if session.isBusy && session.streamingText.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white).controlSize(.small)
                        Text("Reading the screen…").font(.caption)
                    }
                } else if panelExpanded {
                    // Only the expanded panel is given a size of its own: a long
                    // answer someone asked to see in full needs a bound, and by
                    // then they have chosen to cover the picture.
                    ScrollView {
                        Text(session.streamingText)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                } else {
                    Text(session.streamingText)
                        .font(.caption)
                        .lineLimit(4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            // Tapping the answer grows it, rather than it always taking the room
            // a long answer might need.
            .onTapGesture { withAnimation { panelExpanded.toggle() } }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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
