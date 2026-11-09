#if os(iOS) || os(macOS)
@preconcurrency import AVFoundation
import os
import LumaCore

// Camera adapter. On iOS, other apps' screens can't be read without a broadcast
// extension; on macOS, DRM video (Netflix, YouTube TV) captures as black, so a
// camera aimed at the TV is the honest workaround. Frames are reduced to the same
// coarse color grid as screen capture on a private queue; pixels are never stored or sent.

extension ScreenSource {
    #if os(iOS)
    static var camera: ScreenSource { ScreenSource(name: "Back camera", kind: .camera) { CameraScreenCapture() } }
    #else
    /// Built-in, USB, and Continuity Camera devices, by name. Listing reads no frames
    /// and needs no permission; macOS asks once the person starts a camera.
    static var cameras: [ScreenSource] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified)
            .devices.map { device in
                let id = device.uniqueID
                return ScreenSource(name: device.localizedName, kind: .camera) { CameraScreenCapture(deviceID: id) }
            }
    }
    #endif
}

final class CameraScreenCapture: ScreenCaptureSession {
    /// The chosen camera on macOS; nil picks the back camera on iOS.
    private let deviceID: String?
    private var session: AVCaptureSession?
    private var output: CameraFrameOutput?
    private var observers: [any NSObjectProtocol] = []
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    init(deviceID: String? = nil) { self.deviceID = deviceID }

    func start(onFrame: @escaping @MainActor (ScreenGrid, ContinuousClock.Instant) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw ScreenCaptureEnd.permissionDenied }
        let device = if let deviceID { AVCaptureDevice(uniqueID: deviceID) }
                     else { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video) }
        guard let device else { throw deviceID == nil ? ScreenCaptureEnd.failed("No camera is available.") : .sourceGone }
        let session = AVCaptureSession()
        // The lowest preset is plenty: the analyzer reduces to a 30×18 grid.
        if session.canSetSessionPreset(.low) { session.sessionPreset = .low }
        let input = try AVCaptureDeviceInput(device: device)
        let video = AVCaptureVideoDataOutput()
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        #if os(macOS)
        // Continuity Camera can refuse `.low`; scale every camera to about the 160-pixel
        // frames screen capture uses. A 4:3 webcam is squeezed, which regions don't mind.
        settings[kCVPixelBufferWidthKey as String] = 160
        settings[kCVPixelBufferHeightKey as String] = 90
        #endif
        video.videoSettings = settings
        video.alwaysDiscardsLateVideoFrames = true
        let output = CameraFrameOutput(onFrame: onFrame, onEnd: onEnd)
        video.setSampleBufferDelegate(output, queue: output.queue)
        guard session.canAddInput(input), session.canAddOutput(video) else { throw ScreenCaptureEnd.failed("The camera couldn't be configured.") }
        session.addInput(input); session.addOutput(video)
        #if os(macOS)
        // A front-facing webcam may mirror; left/right regions must match the TV.
        if let connection = video.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        #else
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
        #endif
        self.session = session; self.output = output
        // Runtime errors and interruptions (a call, another camera app) end the session.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                MainActor.assumeIsolated { onEnd(.failed(error?.localizedDescription ?? "The camera stopped.")) }
            },
            // Unplugged, or a Continuity Camera iPhone that walked away.
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { _ in
                MainActor.assumeIsolated { onEnd(.sourceGone) }
            }
        ]
        #if os(iOS)
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { _ in
            MainActor.assumeIsolated { onEnd(.failed("Another app is using the camera.")) }
        })
        #endif
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
        // A camera that ignored the BGRA request yields nothing rather than wrong colors.
        guard state.withLock({ !$0.cancelled && !$0.scheduled }), let pixels = sampleBuffer.imageBuffer,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
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
