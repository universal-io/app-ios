import SwiftUI

struct ContentView: View {
    @State private var camera = CameraService()
    @State private var session = AnalysisSession()
    @State private var pendingTap: CGPoint?
    @State private var showingProbe = false
    @State private var showingMirror = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch session.phase {
            case .framing:
                framingView
            case .analyzing, .answered, .failed:
                answerView
            }
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Framing

    private var framingView: some View {
        VStack(spacing: 0) {
            ZStack {
                switch camera.state {
                case .running:
                    CameraPreviewView(session: camera.session) { layer in
                        camera.attachPreview(layer)
                    }
                case .denied:
                    message(
                        "Camera access is off",
                        detail: "Turn it on in Settings to explain the screen in front of you."
                    )
                case .failed(let reason):
                    message("The camera could not start", detail: reason)
                case .idle:
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            TextField("Ask about this screen (optional)", text: $session.question)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)

            Button {
                capture()
            } label: {
                Label("Explain this screen", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(camera.state != .running)

            if !AppConfig.isConfigured {
                Text("No beta token is set in this build; requests will be rejected.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 16) {
                Button("Mirror a Mac") { showingMirror = true }
                // Measurement scaffolding for M4, kept because the link is
                // worth re-measuring whenever the transport changes.
                Button("Link probe") { showingProbe = true }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showingProbe) { MirrorProbeView() }
        .fullScreenCover(isPresented: $showingMirror) { MirrorView() }
    }

    // MARK: - Answer

    private var answerView: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image = session.capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()

                    if let result = session.result {
                        AnnotationOverlay(annotations: result.annotations, imageSize: image.size)
                    }
                }

                if session.isBusy && session.streamingText.isEmpty {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            answerPanel
        }
    }

    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .failed(let reason) = session.phase {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                ScrollView {
                    Text(session.streamingText)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }

            // The applied context pack is always visible: knowledge the user
            // cannot see is knowledge they cannot question or correct.
            if let pack = session.result?.appliedContextPack {
                Label(pack, systemImage: "books.vertical")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .none = session.highlightState, session.phase == .answered {
                Text("Nothing on screen was singled out for this answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Take another") { session.reset() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.callout).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding()
    }

    private func capture() {
        Task {
            do {
                let data = try await camera.capturePhoto()
                session.analyze(imageData: data, tapPoint: pendingTap)
                pendingTap = nil
            } catch {
                session.fail(error.localizedDescription)
            }
        }
    }
}

#Preview {
    ContentView()
}
