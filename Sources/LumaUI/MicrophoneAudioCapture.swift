#if os(iOS)
@preconcurrency import AVFoundation
import LumaCore

// Audio Sync on iPhone and iPad. iOS gives apps no way to hear what other apps play, so the
// source is the microphone, which hears music in the room (or from this device's speaker).
// Samples are reduced to `AudioLevels` on the audio thread; nothing is recorded or sent.

extension ScreenSource {
    static var microphone: ScreenSource { .audio(name: "Microphone", kind: .microphone) { MicrophoneAudioCapture() } }
}

final class MicrophoneAudioCapture: AudioCaptureSession {
    private var engine: AVAudioEngine?
    private var pump: AudioLevelPump?
    private var observers: [any NSObjectProtocol] = []

    func start(onLevels: @escaping @MainActor (AudioLevels) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw ScreenCaptureEnd.permissionDenied }
        let session = AVAudioSession.sharedInstance()
        do {
            // Measurement mode turns off voice processing and automatic gain, which flatten
            // music. Mixing keeps any music this device plays going, and A2DP keeps it on a
            // Bluetooth speaker or headphones (playAndRecord clears that route otherwise).
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch { throw ScreenCaptureEnd.failed("The microphone couldn't start: \(error.localizedDescription)") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { Self.deactivate(); throw ScreenCaptureEnd.failed("No microphone is available.") }
        guard let pump = AudioLevelPump(onLevels: onLevels, onEnd: onEnd) else { Self.deactivate(); throw ScreenCaptureEnd.failed("Audio analysis is unavailable.") }
        Self.installTap(on: input, format: format, pump: pump)
        self.engine = engine; self.pump = pump
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { note in
                guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began else { return }
                pump.end(.failed("Another app is using the microphone."))
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
                pump.end(.failed("The audio input changed. Start again to keep listening."))
            }
        ]
        do { try engine.start() } catch {
            stop()
            throw ScreenCaptureEnd.failed("The microphone couldn't start: \(error.localizedDescription)")
        }
    }

    func stop() {
        pump?.cancel(); pump = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Self.deactivate()
    }

    private static func deactivate() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }

    /// Nonisolated so the tap block is not main-actor isolated: it runs on the audio thread.
    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, pump: AudioLevelPump) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
            guard frames > 0, count > 0 else { return }
            var mono = [Float](repeating: 0, count: frames)
            if buffer.format.isInterleaved {
                let samples = channels[0]
                for i in 0..<frames { for c in 0..<count { mono[i] += samples[i * count + c] / Float(count) } }
            } else {
                for c in 0..<count {
                    let samples = channels[c]
                    for i in 0..<frames { mono[i] += samples[i] / Float(count) }
                }
            }
            pump.feed(mono, sampleRate: buffer.format.sampleRate)
        }
    }
}
#endif
