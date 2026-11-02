import Foundation
import os
import LumaCore

/// One running Audio Sync capture. Only `AudioLevels` (loudness + 8 bands) ever leave it,
/// never samples. Like `ScreenCaptureSession`, holding a source captures nothing; only
/// `ScreenSync.start()` creates and starts a session.
protocol AudioCaptureSession: AnyObject {
    func start(onLevels: @escaping @MainActor (AudioLevels) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws
    func stop()
}

/// Mono samples in, about 20 analyses per second out (a 2048-sample `AudioSpectrum` window
/// every 50 ms of audio). Only the latest result reaches the main actor; a busy main thread
/// drops analyses instead of queueing them. `feed` runs on the capture's own thread, one
/// caller at a time; `cancel` and `end` from anywhere. Nothing is stored.
nonisolated final class AudioLevelPump: @unchecked Sendable {
    private struct Slot { var latest: AudioLevels?; var scheduled = false; var cancelled = false }
    private let slot = OSAllocatedUnfairLock(initialState: Slot())
    private let onLevels: @MainActor (AudioLevels) -> Void
    private let onEnd: @MainActor (ScreenCaptureEnd) -> Void
    private let spectrum: AudioSpectrum
    // Touched only by the single feeding thread.
    private var window = [Float](repeating: 0, count: AudioSpectrum.size)
    private var sinceAnalysis = 0

    init?(onLevels: @escaping @MainActor (AudioLevels) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) {
        guard let spectrum = AudioSpectrum() else { return nil }
        self.spectrum = spectrum; self.onLevels = onLevels; self.onEnd = onEnd
    }

    func cancel() { slot.withLock { $0.cancelled = true; $0.latest = nil } }

    func feed(_ mono: [Float], sampleRate rate: Double) {
        guard !mono.isEmpty, rate > 0 else { return }
        if mono.count >= window.count { window = Array(mono.suffix(window.count)) }
        else { window.removeFirst(mono.count); window.append(contentsOf: mono) }
        sinceAnalysis += mono.count
        guard sinceAnalysis >= Int(rate / 20) else { return }
        sinceAnalysis = 0
        if let levels = spectrum.levels(window, sampleRate: rate) { deliver(levels) }
    }

    private func deliver(_ levels: AudioLevels) {
        let schedule = slot.withLock { s -> Bool in
            guard !s.cancelled else { return false }
            s.latest = levels
            if s.scheduled { return false }
            s.scheduled = true; return true
        }
        guard schedule else { return }
        Task { @MainActor in
            let latest = self.slot.withLock { s -> AudioLevels? in
                s.scheduled = false
                defer { s.latest = nil }
                return s.cancelled ? nil : s.latest
            }
            if let latest { self.onLevels(latest) }
        }
    }

    /// Reports the first ending only; later analyses are dropped.
    func end(_ reason: ScreenCaptureEnd) {
        let first = slot.withLock { s -> Bool in
            defer { s.cancelled = true }
            return !s.cancelled
        }
        guard first else { return }
        Task { @MainActor in self.onEnd(reason) }
    }
}
