import Foundation

/// Tells speech from silence by comparing each chunk's loudness with the room's noise floor,
/// which it learns as it goes. A fixed threshold doesn't work: on this Mac the built-in mic's
/// floor has measured anywhere from 0.002 to 0.016 RMS, while speech sits only 1.5–5× above it.
struct VoiceActivityDetector: Sendable {
    /// Louder than the floor by this factor counts as voice.
    var ratio: Float = 2.2
    /// Never call anything this quiet voice, whatever the floor.
    var absoluteMinimum: Float = 0.004
    private(set) var floor: Float?

    /// `rms` of one audio chunk (about 0.1 s). Returns whether it holds voice.
    mutating func isVoice(rms: Float) -> Bool {
        guard let current = floor else {
            floor = max(rms, 0.0005)
            return false
        }
        let isVoice = rms > max(current * ratio, absoluteMinimum)
        if rms < current {
            // Quieter than we thought the room was: follow it down quickly.
            floor = max(rms, 0.0005)
        } else if !isVoice {
            // Background drifting up (a fan starting): follow it slowly.
            floor = current + (rms - current) * 0.02
        }
        return isVoice
    }
}

/// Shortens long silences in the saved recording. Silence shorter than `maxKept` is kept as is.
/// A longer one keeps `edge` seconds at each end and drops the middle, so a pause to read a PRD
/// doesn't cost minutes of audio. Generic over the chunk type so it can be tested without audio.
struct SilenceTrimmer<Chunk> {
    /// Silences up to this long are kept whole.
    let maxKept: TimeInterval
    /// What's kept at each end of a longer silence.
    let edge: TimeInterval

    /// Silence written so far in the current run (its leading edge).
    private var writtenSilence: TimeInterval = 0
    /// Silence held back after the leading edge, until we know whether it runs long.
    private var pending: [(chunk: Chunk, seconds: TimeInterval)] = []
    private var pendingSeconds: TimeInterval = 0
    /// Whether the current run has gone past `maxKept` (so its middle is being dropped).
    private var isTrimming = false
    private(set) var trimmedSeconds: TimeInterval = 0

    init(maxKept: TimeInterval = 30, edge: TimeInterval = 1) {
        self.maxKept = maxKept
        self.edge = edge
    }

    /// Takes the next chunk and returns the chunks to write now, in order.
    mutating func add(_ chunk: Chunk, seconds: TimeInterval, isVoice: Bool) -> [Chunk] {
        if isVoice {
            var out = flushPending()
            out.append(chunk)
            writtenSilence = 0
            return out
        }
        if writtenSilence < edge {
            writtenSilence += seconds
            return [chunk]
        }
        pending.append((chunk, seconds))
        pendingSeconds += seconds
        let runLength = writtenSilence + pendingSeconds
        if runLength > maxKept {
            isTrimming = true
        }
        if isTrimming {
            // Only the trailing edge is still needed; drop older silence.
            while pendingSeconds - (pending.first?.seconds ?? 0) >= edge, !pending.isEmpty {
                let dropped = pending.removeFirst()
                pendingSeconds -= dropped.seconds
                trimmedSeconds += dropped.seconds
            }
        }
        return []
    }

    /// At the end of the recording: whatever silence is still held back.
    mutating func finish() -> [Chunk] {
        flushPending()
    }

    private mutating func flushPending() -> [Chunk] {
        let out = pending.map(\.chunk)
        pending = []
        pendingSeconds = 0
        isTrimming = false
        return out
    }
}
