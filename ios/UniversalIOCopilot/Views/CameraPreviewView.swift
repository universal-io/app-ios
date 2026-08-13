import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview. Uses `.resizeAspect` so the preview frames the shot the
/// same way the captured photo will be analyzed and annotated.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // Safe: layerClass above guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
