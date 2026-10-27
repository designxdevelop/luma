#if os(iOS)
@preconcurrency import AVFoundation
import os
import LumaCore

// Camera adapter for iOS, where other apps' screens can't be read without a
// broadcast extension. Frames are reduced to the same coarse color grid as
// macOS capture on a private queue; pixels are never stored or sent.

extension ScreenSource {
    static var camera: ScreenSource { ScreenSource(name: "Back camera", kind: .camera) { CameraScreenCapture() } }
}

final class CameraScreenCapture: ScreenCaptureSession {
    private var session: AVCaptureSession?
    private var output: CameraFrameOutput?
    private var observers: [any NSObjectProtocol] = []
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    func start(onFrame: @escaping @MainActor (ScreenGrid, ContinuousClock.Instant) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw ScreenCaptureEnd.permissionDenied }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video) else {
            throw ScreenCaptureEnd.failed("No camera is available.")
        }
        let session = AVCaptureSession()
        // The lowest preset is plenty: the analyzer reduces to a 30×18 grid.
        session.sessionPreset = .low
        let input = try AVCaptureDeviceInput(device: device)
        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        let output = CameraFrameOutput(onFrame: onFrame, onEnd: onEnd)
        video.setSampleBufferDelegate(output, queue: output.queue)
        guard session.canAddInput(input), session.canAddOutput(video) else { throw ScreenCaptureEnd.failed("The camera couldn't be configured.") }
        session.addInput(input); session.addOutput(video)
        // Keep the frame upright however the phone is held, so left/right/top/bottom
        // regions match the TV.
        if let connection = video.connection(with: .video) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            let apply = { @Sendable (angle: CGFloat) in
                output.queue.async { if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle } }
            }
            apply(coordinator.videoRotationAngleForHorizonLevelCapture)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { _, change in
                if let angle = change.newValue { apply(angle) }
            }
            rotation = coordinator
        }
        self.session = session; self.output = output
        // Runtime errors and interruptions (a call, another camera app) end the session.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                MainActor.assumeIsolated { onEnd(.failed(error?.localizedDescription ?? "The camera stopped.")) }
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { _ in
                MainActor.assumeIsolated { onEnd(.failed("Another app is using the camera.")) }
            }
        ]
        let running = await withCheckedContinuation { done in output.queue.async { session.startRunning(); done.resume(returning: session.isRunning) } }
        guard running else { stop(); throw ScreenCaptureEnd.failed("The camera couldn't start.") }
    }

    func stop() {
        output?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        rotationObservation = nil; rotation = nil
        guard let session, let output else { return }
        self.session = nil; self.output = nil
        output.queue.async { session.stopRunning() }
    }
}

/// Hands only the latest grid to the main actor; a busy main thread drops frames.
private final class CameraFrameOutput: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    nonisolated let queue = DispatchQueue(label: "app.luma.screen-sync.camera", qos: .utility)
    nonisolated private let state = OSAllocatedUnfairLock(initialState: (scheduled: false, cancelled: false))
    nonisolated private let onFrame: @MainActor (ScreenGrid, ContinuousClock.Instant) -> Void
    nonisolated private let onEnd: @MainActor (ScreenCaptureEnd) -> Void

    nonisolated init(onFrame: @escaping @MainActor (ScreenGrid, ContinuousClock.Instant) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) {
        self.onFrame = onFrame; self.onEnd = onEnd
    }

    nonisolated func cancel() { state.withLock { $0.cancelled = true } }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard state.withLock({ !$0.cancelled && !$0.scheduled }), let pixels = sampleBuffer.imageBuffer,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let height = CVPixelBufferGetHeight(pixels), bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        guard let grid = ScreenColorMath.analyze(bytes, width: CVPixelBufferGetWidth(pixels), height: height, bytesPerRow: bytesPerRow) else { return }
        let capturedAt = ContinuousClock.now
        state.withLock { $0.scheduled = true }
        Task { @MainActor in
            let deliver = self.state.withLock { s -> Bool in s.scheduled = false; return !s.cancelled }
            if deliver { self.onFrame(grid, capturedAt) }
        }
    }
}
#endif
