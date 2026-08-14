import AVFoundation
import UIKit

/// Camera capture for the mode that reads any screen in front of you — another
/// computer, a kiosk, a printer panel. v1 works from stills: one photo, one
/// analysis, annotations drawn over that frozen frame.
@MainActor
@Observable
final class CameraService: NSObject {
    enum State: Equatable {
        case idle
        case running
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle

    // AVCaptureSession is not Sendable and must not be started or stopped on the
    // main thread, so it is driven from a dedicated serial queue instead.
    nonisolated(unsafe) let session = AVCaptureSession()
    private nonisolated let sessionQueue = DispatchQueue(label: "com.universalio.copilot.camera")

    private let photoOutput = AVCapturePhotoOutput()
    private var captureContinuation: CheckedContinuation<Data, Error>?

    // Rotation is not ours to derive. Deducing an angle from the interface or
    // device orientation is the classic way to get a preview that is upright and
    // a photo that is not — the two need different angles, and the device
    // orientation alone cannot tell them apart. iOS 17 answers this with
    // `RotationCoordinator`, which watches the device against gravity and hands
    // back one angle for each side. Apple's guidance is to apply what it returns
    // rather than compute anything, so that is all this class does.
    //
    // Both angles have to be applied, to two different connections that are
    // owned in two different places: the preview layer belongs to the SwiftUI
    // view, the photo output belongs here. `attachPreview` is where they meet.
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservers: [NSKeyValueObservation] = []

    struct CaptureError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    func start() async {
        guard state != .running else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .denied
                return
            }
        default:
            state = .denied
            return
        }

        if session.inputs.isEmpty {
            do {
                try configure()
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }
        // Starts the capture side tracking gravity immediately. The preview side
        // joins later, when the view hands its layer over.
        trackRotation()

        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.session.startRunning()
                continuation.resume()
            }
        }
        state = .running
    }

    func stop() {
        guard state == .running else { return }
        state = .idle
        sessionQueue.async { self.session.stopRunning() }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            throw CaptureError(message: "No usable back camera on this device.")
        }
        session.addInput(input)
        self.device = device

        guard session.canAddOutput(photoOutput) else {
            throw CaptureError(message: "The camera could not be prepared for capture.")
        }
        session.addOutput(photoOutput)
    }

    /// Takes ownership of the preview layer's rotation.
    ///
    /// The layer is built by the SwiftUI view but the angle that keeps it level
    /// comes from the device, which lives here — so the view hands the layer over
    /// and this class drives both sides from one coordinator. Safe to call again
    /// with a new layer: the view is torn down whenever a photo is taken and
    /// rebuilt on the next round.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        trackRotation()
    }

    /// Rebuilds the coordinator for the current device and preview layer, and
    /// keeps applying its angles for as long as they change.
    private func trackRotation() {
        rotationObservers.removeAll()

        guard let device else {
            rotationCoordinator = nil
            return
        }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        // `.initial` applies the current angles now; the coordinator then reports
        // every change, so the preview follows the device as it is turned instead
        // of being correct only at launch. Apple delivers these on the main queue,
        // but the hop is left explicit rather than assumed.
        rotationObservers = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                Task { @MainActor in self?.apply(previewAngle: angle) }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                Task { @MainActor in self?.apply(captureAngle: angle) }
            },
        ]
    }

    private func apply(previewAngle angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
    }

    /// On a photo output this is recorded as an EXIF orientation rather than by
    /// turning the pixels, which is why `AnalysisSession` still has to bake that
    /// flag in before the bytes are uploaded and drawn on.
    private func apply(captureAngle angle: CGFloat) {
        guard let connection = photoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
    }

    /// Returns JPEG data for one frame.
    func capturePhoto() async throws -> Data {
        guard state == .running else {
            throw CaptureError(message: "The camera is not running.")
        }
        guard captureContinuation == nil else {
            throw CaptureError(message: "A capture is already in progress.")
        }

        let settings = AVCapturePhotoSettings(format: [
            AVVideoCodecKey: AVVideoCodecType.jpeg.rawValue
        ])

        return try await withCheckedThrowingContinuation { continuation in
            captureContinuation = continuation
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraService: @preconcurrency AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let continuation = captureContinuation
        captureContinuation = nil

        if let error {
            continuation?.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation?.resume(throwing: CaptureError(message: "The captured photo could not be read."))
            return
        }
        continuation?.resume(returning: data)
    }
}
