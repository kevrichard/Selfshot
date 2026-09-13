import AVFoundation
import SwiftUI
import UIKit

/// Thin UIKit wrapper around AVCaptureVideoPreviewLayer.
/// SwiftUI has no native preview view, so this is still the way.
///
/// Handles its own tap recognizer because converting a screen point into
/// capture-device space needs the preview layer, which only exists here.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Delivers the tap as (devicePoint, layerPoint): the first already
    /// converted to capture-device space (0…1), the second in view
    /// coordinates so the UI can draw a reticle there.
    var onTap: ((CGPoint, CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap

        let recognizer = UITapGestureRecognizer(target: view, action: #selector(PreviewView.handleTap(_:)))
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onTap = onTap
    }

    final class PreviewView: UIView {
        var onTap: ((CGPoint, CGPoint) -> Void)?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            let location = recognizer.location(in: self)
            let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: location)
            onTap?(devicePoint, location)
        }
    }
}
