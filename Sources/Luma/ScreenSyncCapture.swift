import Foundation
import AppKit
import CoreMedia
import CoreVideo
import os
@preconcurrency import ScreenCaptureKit
import LumaCore

// ScreenCaptureKit adapter. The system picker is the only way a real source is
// chosen: Luma never enumerates shareable content or preflights permission.
// Frames are reduced to five region colors on a private queue; pixels are
// never stored, logged, or sent anywhere.

extension ScreenSource {
    static func system(_ filter: SCContentFilter) -> ScreenSource {
        let isWindow = filter.style == .window
        var name = isWindow ? "Selected window" : "Selected display"
        if #available(macOS 15.2, *) {
            if isWindow, let window = filter.includedWindows.first {
                let app = window.owningApplication?.applicationName ?? ""
                let title = window.title ?? ""
                name = [app, title].filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty ?? name
            } else if let display = filter.includedDisplays.first {
                name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.localizedName ?? name
            }
        }
        return ScreenSource(name: name, kind: isWindow ? .window : .display) { SystemScreenCapture(filter: filter) }
    }

    /// Synthetic letterboxed frames for the demo home. Runs through the same
    /// analyzer as real capture; nothing on screen is read.
    static var sample: ScreenSource { ScreenSource(name: "Sample video", kind: .sample) { SampleScreenCapture() } }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

// MARK: - System picker

final class ScreenSourcePicker: NSObject, SCContentSharingPickerObserver {
    enum Result { case picked(ScreenSource), cancelled, failed(String) }
    static let shared = ScreenSourcePicker()
    private var completion: ((Result) -> Void)?
    private var observing = false

    func present(_ completion: @escaping (Result) -> Void) {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let id = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [id] }
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        if !observing { picker.add(self); observing = true }
        self.completion = completion
        picker.isActive = true
        picker.present()
    }

    func deactivate() {
        completion = nil
        guard observing else { return }
        SCContentSharingPicker.shared.remove(self); observing = false
        SCContentSharingPicker.shared.isActive = false
    }

    private func finish(_ result: Result) {
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(.cancelled) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in self.finish(.picked(.system(filter))) }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let text = error.localizedDescription
        Task { @MainActor in self.finish(.failed(text)) }
    }
}

// MARK: - ScreenCaptureKit session

final class SystemScreenCapture: ScreenCaptureSession {
    private let filter: SCContentFilter
    private var stream: SCStream?
    private var output: FrameOutput?

    init(filter: SCContentFilter) { self.filter = filter }

    func start(onFrame: @escaping @MainActor (RegionColors) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws {
        let configuration = SCStreamConfiguration()
        // Downsampled by the system before Luma sees a frame: at most 160 pixels
        // on the long side, matching the source's shape so padding stays minimal.
        let size = filter.contentRect.size
        let aspect = size.width > 0 && size.height > 0 ? size.height / size.width : 9.0 / 16
        let longSide = 160.0
        configuration.width = Int(aspect <= 1 ? longSide : max(2, (longSide / aspect).rounded()))
        configuration.height = Int(aspect <= 1 ? max(2, (longSide * aspect).rounded()) : longSide)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureResolution = .nominal
        configuration.streamName = "Luma Screen Sync"
        let output = FrameOutput(onFrame: onFrame, onEnd: onEnd)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            self.stream = stream; self.output = output
            try await stream.startCapture()
            // Stop can arrive while macOS is still starting (or asking for consent),
            // when the system may ignore it. Stop again once start completes.
            if self.stream !== stream { try? await stream.stopCapture() }
        } catch {
            output.cancel()
            self.stream = nil; self.output = nil
            throw FrameOutput.ending(for: error)
        }
    }

    func stop() {
        output?.cancel()
        guard let stream else { return }
        self.stream = nil; output = nil
        // The completion holds the stream until the system confirms it stopped.
        stream.stopCapture { _ in _ = stream }
    }
}

/// Receives frames on its own queue and hands only the latest region colors
/// to the main actor. A slow main thread drops frames instead of queueing them.
private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    nonisolated let queue = DispatchQueue(label: "app.luma.screen-sync.frames", qos: .utility)
    private struct Slot { var latest: RegionColors?; var scheduled = false; var cancelled = false }
    nonisolated private let slot = OSAllocatedUnfairLock(initialState: Slot())
    nonisolated private let onFrame: @MainActor (RegionColors) -> Void
    nonisolated private let onEnd: @MainActor (ScreenCaptureEnd) -> Void

    nonisolated init(onFrame: @escaping @MainActor (RegionColors) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) {
        self.onFrame = onFrame; self.onEnd = onEnd
    }

    nonisolated func cancel() { slot.withLock { $0.cancelled = true; $0.latest = nil } }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .stopped { end(.sourceGone); return }
        // Idle means unchanged; blank, suspended and started frames carry no picture.
        guard status == .complete, let pixels = sampleBuffer.imageBuffer,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let height = CVPixelBufferGetHeight(pixels), bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        guard let colors = ScreenColorMath.analyze(bytes, width: CVPixelBufferGetWidth(pixels), height: height, bytesPerRow: bytesPerRow) else { return }
        deliver(colors)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) { end(Self.ending(for: error)) }

    nonisolated private func deliver(_ colors: RegionColors) {
        let schedule = slot.withLock { s -> Bool in
            guard !s.cancelled else { return false }
            s.latest = colors
            if s.scheduled { return false }
            s.scheduled = true; return true
        }
        guard schedule else { return }
        Task { @MainActor in
            let latest = self.slot.withLock { s -> RegionColors? in
                s.scheduled = false
                defer { s.latest = nil }
                return s.cancelled ? nil : s.latest
            }
            if let latest { self.onFrame(latest) }
        }
    }

    nonisolated private func end(_ reason: ScreenCaptureEnd) {
        let first = slot.withLock { s -> Bool in
            defer { s.cancelled = true }
            return !s.cancelled
        }
        guard first else { return }
        Task { @MainActor in self.onEnd(reason) }
    }

    nonisolated static func ending(for error: any Error) -> ScreenCaptureEnd {
        guard let error = error as? SCStreamError else { return .failed(error.localizedDescription) }
        switch error.code {
        case .userDeclined: return .permissionDenied
        case .userStopped: return .userStopped
        case .noCaptureSource, .noDisplayList, .noWindowList: return .sourceGone
        default: return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Demo sample

/// Generates 160×90 BGRA frames with letterbox bars and two slowly drifting
/// hues, so the full pipeline can be exercised without capturing the screen.
final class SampleScreenCapture: ScreenCaptureSession {
    private var task: Task<Void, Never>?

    func start(onFrame: @escaping @MainActor (RegionColors) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws {
        task = Task {
            var phase = 0.0
            while !Task.isCancelled {
                if let colors = Self.frame(phase: phase) { onFrame(colors) }
                phase += 0.01
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    static func frame(phase: Double, width: Int = 160, height: Int = 90, bar: Int = 10) -> RegionColors? {
        func bgra(hue: Double) -> [UInt8] {
            let c = NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.9, alpha: 1)
            return [UInt8(c.blueComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.redComponent * 255), 255]
        }
        let left = bgra(hue: phase), right = bgra(hue: phase + 0.33)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in bar..<(height - bar) {
            for x in 0..<width {
                let o = (y * width + x) * 4
                pixels.replaceSubrange(o..<(o + 4), with: x < width / 2 ? left : right)
            }
        }
        return pixels.withUnsafeBytes { ScreenColorMath.analyze($0, width: width, height: height, bytesPerRow: width * 4) }
    }
}
