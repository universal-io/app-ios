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

        guard session.canAddOutput(photoOutput) else {
            throw CaptureError(message: "The camera could not be prepared for capture.")
        }
        session.addOutput(photoOutput)
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
