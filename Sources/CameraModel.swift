import AVFoundation
import Photos
import UIKit

enum CaptureMode {
    case photo
    case video
}

/// Which camera + focal length we're shooting at.
/// The rear options are the flattering ones; `.front` exists so you can
/// actually see the preview when the phone is propped up 6 feet away.
enum LensChoice: String, CaseIterable, Identifiable {
    case front = "Front"
    case wide1x = "1x"
    case wide2x = "2x"
    case tele4x = "4x"
    case tele8x = "8x"

    var id: String { rawValue }

    var isFront: Bool { self == .front }

    /// Zoom as the Camera app labels it, where 1x is the main camera.
    /// This is NOT the raw `videoZoomFactor` — on a virtual device that
    /// includes an ultra-wide, raw 1.0 is the ultra-wide (0.5x), so this gets
    /// rescaled in `applyZoom`.
    var displayZoom: CGFloat {
        switch self {
        case .front:  return 1.0
        case .wide1x: return 1.0
        case .wide2x: return 2.0
        case .tele4x: return 4.0
        case .tele8x: return 8.0
        }
    }

    /// Roughly how far back you need to stand for a flattering result.
    var suggestedDistance: String {
        switch self {
        case .front:  return "5–7 ft"
        case .wide1x: return "8–10 ft"
        case .wide2x: return "8–10 ft"
        case .tele4x: return "10–14 ft"
        case .tele8x: return "20+ ft"
        }
    }
}

/// NOTE ON THREADING — this is what crashed v1.
///
/// This class is deliberately NOT `@MainActor`. An AVCaptureSession must be
/// configured off the main thread (configuration blocks for hundreds of ms),
/// so the capture graph is owned exclusively by `sessionQueue`. Meanwhile
/// SwiftUI requires every `@Published` mutation on the main thread.
///
/// The rule here: capture-graph state is touched ONLY inside `sessionQueue`
/// blocks, and every `@Published` write goes through `publish { }`. Public
/// methods are called from the main thread, read what they need there, and
/// hand plain values across the queue boundary — never `self.someProperty`
/// read from inside a background block.
final class CameraModel: NSObject, ObservableObject {

    // MARK: - Published state (main thread only)

    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var lastError: String?
    @Published private(set) var maxPhotoMegapixels: Int = 12
    @Published private(set) var shotsInBurstRemaining: Int = 0
    @Published private(set) var isLocked = false
    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var lens: LensChoice = .front

    // MARK: - Capture graph (sessionQueue only)

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "selfshot.session")

    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    /// Photo delegates must be retained until their callbacks fire.
    private var inFlightDelegates: [Int64: PhotoCaptureDelegate] = [:]

    /// sessionQueue's own copy of what we're configured for, so background
    /// code never reads the @Published versions.
    private var activeMode: CaptureMode = .photo
    private var activeLens: LensChoice = .front

    private var burstTimer: DispatchSourceTimer?

    // MARK: - Main-thread publishing helper

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func report(_ message: String) {
        publish { self.lastError = message }
    }

    // MARK: - Lifecycle

    func start() {
        Task {
            let granted = await requestPermissions()
            guard granted else {
                self.report("Camera or Photos permission denied — check Settings.")
                return
            }
            let mode = await MainActor.run { self.mode }
            let lens = await MainActor.run { self.lens }

            self.sessionQueue.async {
                self.activeMode = mode
                self.activeLens = lens
                self.configureSession()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let running = self.session.isRunning
                self.publish { self.isRunning = running }
            }
        }
    }

    func stop() {
        cancelBurst()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.publish { self.isRunning = false }
        }
    }

    private func requestPermissions() async -> Bool {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        let photos = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) }
        }
        return camera && (photos == .authorized || photos == .limited)
    }

    // MARK: - Session configuration (sessionQueue only)

    private func configureSession() {
        session.beginConfiguration()

        // `.photo` is required for 24MP / 48MP support. For video we swap to a
        // 4K preset, since the photo preset caps movie output resolution.
        let wantedPreset: AVCaptureSession.Preset = (activeMode == .photo) ? .photo : .hd4K3840x2160
        if session.canSetSessionPreset(wantedPreset) {
            session.sessionPreset = wantedPreset
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        configureVideoInput()
        configureAudioInput()
        configureOutputs()

        session.commitConfiguration()
    }

    private func configureVideoInput() {
        if let existing = videoDeviceInput {
            session.removeInput(existing)
            videoDeviceInput = nil
        }

        guard let device = resolveDevice(for: activeLens) else {
            report("No camera available for \(activeLens.rawValue).")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                report("Couldn't attach the \(activeLens.rawValue) camera.")
                return
            }
            session.addInput(input)
            videoDeviceInput = input
            applyZoom(on: device)
            reportMaxResolution(for: device)
        } catch {
            report("Couldn't open camera: \(error.localizedDescription)")
        }
    }

    private func configureAudioInput() {
        // Audio only matters in video mode; dropping it in photo mode avoids
        // needlessly grabbing the mic (and the orange dot).
        if let existing = audioDeviceInput {
            session.removeInput(existing)
            audioDeviceInput = nil
        }
        guard activeMode == .video,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        audioDeviceInput = input
    }

    private func configureOutputs() {
        switch activeMode {
        case .photo:
            if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            configurePhotoOutput()

        case .video:
            if session.outputs.contains(photoOutput) { session.removeOutput(photoOutput) }
            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
            if let connection = movieOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = activeLens.isFront
                }
            }
        }
    }

    private func configurePhotoOutput() {
        photoOutput.maxPhotoQualityPrioritization = .quality

        if let device = videoDeviceInput?.device {
            let dimensions = device.activeFormat.supportedMaxPhotoDimensions
            if let best = dimensions.max(by: {
                Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
            }) {
                photoOutput.maxPhotoDimensions = best
            }
        }

        // Deferred processing hands you a lightweight proxy immediately and
        // finishes the heavy fusion work in the background — this is what keeps
        // burst mode from stalling between frames.
        if photoOutput.isAutoDeferredPhotoDeliverySupported {
            photoOutput.isAutoDeferredPhotoDeliveryEnabled = true
        }

        // Pre-allocating buffers removes the first-shot delay.
        let warmup = AVCapturePhotoSettings()
        warmup.photoQualityPrioritization = .quality
        warmup.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        photoOutput.setPreparedPhotoSettingsArray([warmup], completionHandler: nil)
    }

    private func resolveDevice(for lens: LensChoice) -> AVCaptureDevice? {
        if lens.isFront {
            // On iPhone 17 the front camera is the square Center Stage sensor,
            // reported as an ultra-wide. Fall back to the classic front wide
            // angle on older hardware.
            if let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front) {
                return ultra
            }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        // Prefer the virtual multi-camera device so zooming crosses between
        // physical lenses automatically instead of us picking one by hand.
        return AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// On a virtual device the raw zoom scale is anchored to the *widest*
    /// constituent. If that's the ultra-wide, raw 1.0 is what the Camera app
    /// calls 0.5x — so "1x" really means raw 2.0. This finds that offset.
    private func displayZoomBase(for device: AVCaptureDevice) -> CGFloat {
        guard let widest = device.constituentDevices.first,
              widest.deviceType == .builtInUltraWideCamera,
              let firstSwitchover = device.virtualDeviceSwitchOverVideoZoomFactors.first else {
            return 1.0
        }
        return CGFloat(truncating: firstSwitchover)
    }

    private func applyZoom(on device: AVCaptureDevice) {
        guard !activeLens.isFront else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let base = displayZoomBase(for: device)
            var target = activeLens.displayZoom * base

            // Snap to an exact switchover point when we're close to one. This
            // is what guarantees 4x actually engages the physical telephoto
            // rather than digitally cropping the main sensor.
            let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            if target > 0,
               let nearest = switchovers.min(by: { abs($0 - target) < abs($1 - target) }),
               abs(nearest - target) / target < 0.08 {
                target = nearest
            }

            device.videoZoomFactor = min(max(target, device.minAvailableVideoZoomFactor),
                                         device.maxAvailableVideoZoomFactor)
        } catch {
            // Non-fatal: we just stay at whatever zoom the device came up at.
        }
    }

    private func reportMaxResolution(for device: AVCaptureDevice) {
        let best = device.activeFormat.supportedMaxPhotoDimensions.map {
            Int($0.width) * Int($0.height)
        }.max() ?? 12_000_000
        let megapixels = Int((Double(best) / 1_000_000).rounded())
        publish { self.maxPhotoMegapixels = max(megapixels, 1) }
    }

    // MARK: - Reconfiguration (called from main)

    func switchLens(to newLens: LensChoice) {
        guard newLens != lens else { return }
        lens = newLens
        cancelBurst()
        sessionQueue.async {
            self.activeLens = newLens
            self.session.beginConfiguration()
            self.configureVideoInput()
            self.configureOutputs()
            self.session.commitConfiguration()
            self.publish { self.isLocked = false }
        }
    }

    func switchMode(to newMode: CaptureMode) {
        guard newMode != mode else { return }
        mode = newMode
        cancelBurst()
        sessionQueue.async {
            self.activeMode = newMode
            self.configureSession()
        }
    }

    // MARK: - Focus & exposure

    /// `point` is in capture-device space (0,0 top-left → 1,1 bottom-right),
    /// already converted by the preview layer.
    func focusAndExpose(at point: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                }
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
            } catch {
                self.report("Focus failed: \(error.localizedDescription)")
                return
            }
            self.publish { self.isLocked = false }
        }
    }

    /// Freezes focus and exposure where they are. Essential when you're about
    /// to walk out of frame and back in — otherwise the camera refocuses on
    /// the wall behind you and drifts exposure between burst frames.
    func toggleLock() {
        let shouldLock = !isLocked
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if shouldLock {
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                }
            } catch {
                self.report("Lock failed: \(error.localizedDescription)")
                return
            }
            self.publish { self.isLocked = shouldLock }
        }
    }

    // MARK: - Photo capture

    /// Fires `count` frames back to back. Ten frames of you mid-movement beats
    /// one frame of you posing — that's the whole point of this app.
    func captureBurst(count: Int) {
        guard mode == .photo, count > 0 else { return }
        cancelBurst()
        shotsInBurstRemaining = count

        // ~0.35s spacing keeps expressions varied without thrashing the ISP.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.35)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.shotsInBurstRemaining > 0 else {
                self.cancelBurst()
                return
            }
            self.capturePhoto()
            SoundCue.shutter()
            self.shotsInBurstRemaining -= 1
        }
        burstTimer = timer
        timer.resume()
    }

    func cancelBurst() {
        burstTimer?.cancel()
        burstTimer = nil
        publish { self.shotsInBurstRemaining = 0 }
    }

    private func capturePhoto() {
        sessionQueue.async {
            guard self.session.isRunning, self.session.outputs.contains(self.photoOutput) else { return }

            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.flashMode = .off

            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                // Mirrored front shots match what you saw in the preview, which
                // is also the version of your face you're used to seeing.
                connection.isVideoMirrored = self.activeLens.isFront
            }

            let id = settings.uniqueID
            let delegate = PhotoCaptureDelegate { [weak self] error in
                guard let self else { return }
                if let error { self.report(error) }
                self.sessionQueue.async { self.inFlightDelegates[id] = nil }
            }
            self.inFlightDelegates[id] = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - Video capture

    func toggleRecording() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                guard self.session.outputs.contains(self.movieOutput) else { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("selfshot-\(UUID().uuidString).mov")
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                self.publish { self.isRecording = true }
            }
        }
    }
}

// MARK: - Movie delegate

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        publish { self.isRecording = false }

        if let error {
            report("Recording failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset()
                .addResource(with: .video, fileURL: outputFileURL, options: nil)
        } completionHandler: { [weak self] _, error in
            try? FileManager.default.removeItem(at: outputFileURL)
            if let error {
                self?.report("Couldn't save video: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Photo delegate

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onFinish: (String?) -> Void

    init(onFinish: @escaping (String?) -> Void) {
        self.onFinish = onFinish
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            onFinish("Capture failed: \(error.localizedDescription)")
            return
        }
        save(photo.fileDataRepresentation())
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?,
                     error: Error?) {
        if let error {
            onFinish("Deferred capture failed: \(error.localizedDescription)")
            return
        }
        save(deferredPhotoProxy?.fileDataRepresentation())
    }

    private func save(_ data: Data?) {
        guard let data else {
            onFinish("No image data returned.")
            return
        }
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        } completionHandler: { [weak self] _, error in
            self?.onFinish(error.map { "Couldn't save photo: \($0.localizedDescription)" })
        }
    }
}
