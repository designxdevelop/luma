#if os(macOS)
import Foundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import LumaCore

extension ScreenSource {
    /// Mac audio from a display the person picked in the system picker. A display filter
    /// includes every app, so this is what the Mac plays; Luma itself is excluded twice
    /// (picker `excludedBundleIDs` and `excludesCurrentProcessAudio`).
    static func systemAudio(_ filter: SCContentFilter) -> ScreenSource {
        .audio(name: "Mac audio", kind: .systemAudio) { SystemAudioCapture(filter: filter) }
    }
}

/// Audio Sync capture for the Mac: what this Mac plays, through ScreenCaptureKit audio
/// (`capturesAudio`), excluding Luma's own sound. The filter comes from the same system
/// picker Screen Sync uses, so the person chooses it and macOS shows its capture
/// indicator. Samples are reduced on a private queue to `AudioLevels` about 20 times a second
/// (`AudioLevelPump`); only the latest reaches the main actor, and nothing is stored.
/// ScreenCaptureKit requires a video stream, so it runs at 2×2 pixels, 1 fps, and is never
/// read. `stop()` releases the stream.
final class SystemAudioCapture: AudioCaptureSession {
    private let filter: SCContentFilter
    private var stream: SCStream?
    private var output: AudioLevelOutput?

    init(filter: SCContentFilter) { self.filter = filter }

    func start(onLevels: @escaping @MainActor (AudioLevels) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.streamName = "Luma Audio Sync"
        guard let pump = AudioLevelPump(onLevels: onLevels, onEnd: onEnd) else { throw ScreenCaptureEnd.failed("Audio analysis is unavailable.") }
        let output = AudioLevelOutput(pump: pump)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            // A screen output keeps ScreenCaptureKit from logging dropped frames; its frames are ignored.
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            self.stream = stream; self.output = output
            try await stream.startCapture()
            // Stop can arrive while macOS is still starting (or asking for consent).
            if self.stream !== stream { try? await stream.stopCapture() }
        } catch {
            pump.cancel()
            self.stream = nil; self.output = nil
            throw AudioLevelOutput.ending(for: error)
        }
    }

    func stop() {
        output?.pump.cancel()
        guard let stream else { return }
        self.stream = nil; output = nil
        stream.stopCapture { _ in _ = stream }
    }
}

/// Mixes each audio buffer to mono and feeds the pump, on its own queue.
private final class AudioLevelOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    nonisolated let queue = DispatchQueue(label: "app.luma.audio-sync.samples", qos: .userInitiated)
    nonisolated let pump: AudioLevelPump

    nonisolated init(pump: AudioLevelPump) { self.pump = pump }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              description.mFormatID == kAudioFormatLinearPCM, description.mFormatFlags & kAudioFormatFlagIsFloat != 0, description.mBitsPerChannel == 32 else { return }
        var mono: [Float] = []
        try? sampleBuffer.withAudioBufferList { list, _ in
            let buffers = Array(list)
            guard let first = buffers.first, let base = first.mData else { return }
            if description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                // One buffer per channel.
                let frames = Int(first.mDataByteSize) / 4
                mono = [Float](repeating: 0, count: frames)
                for buffer in buffers {
                    guard let data = buffer.mData, Int(buffer.mDataByteSize) / 4 == frames else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { mono[i] += samples[i] / Float(buffers.count) }
                }
            } else {
                let channels = max(1, Int(description.mChannelsPerFrame)), frames = Int(first.mDataByteSize) / 4 / channels
                let samples = base.assumingMemoryBound(to: Float.self)
                mono = (0..<frames).map { f in (0..<channels).reduce(Float(0)) { $0 + samples[f * channels + $1] } / Float(channels) }
            }
        }
        pump.feed(mono, sampleRate: description.mSampleRate)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) { pump.end(Self.ending(for: error)) }

    nonisolated static func ending(for error: any Error) -> ScreenCaptureEnd {
        guard let error = error as? SCStreamError else { return error as? ScreenCaptureEnd ?? .failed(error.localizedDescription) }
        switch error.code {
        case .userDeclined: return .permissionDenied
        case .userStopped: return .userStopped
        case .noCaptureSource, .noDisplayList, .noWindowList: return .sourceGone
        default: return .failed(error.localizedDescription)
        }
    }
}
#endif
