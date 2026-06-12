import Foundation
import os

/// Estimates how far translated audio lags behind the original speech.
///
/// One sample is taken per utterance: when the first chunk of a Gemini
/// response arrives (response onset), it is matched against the wall time the
/// corresponding speech started. Speech onsets are anchored to Gemini's own
/// input transcription stream — a gap in transcript fragments followed by a
/// new fragment marks a new utterance. (A local energy gate can't segment
/// speech in video content, where music/ambience keeps the level high
/// continuously; the server-side ASR is speech-aware.) The sample also
/// includes any audio already queued for playback at that moment. Per-chunk
/// measurements — and adding playback queue depth while a burst accumulates —
/// systematically overestimate, so neither is done here.
///
/// Thread-safe: can be called from any queue.
final class LatencyTracker: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()

    // EMA state
    private var smoothedLatency: Double = 0
    private var hasInitialSample = false

    // Speech onset detection (input transcription stream)
    private var speechOnsets: [CFAbsoluteTime] = []
    private var lastTranscriptTime: CFAbsoluteTime = 0
    private var isPaused = false

    // Response onset detection (incoming translated audio)
    private var lastReceiveTime: CFAbsoluteTime = 0
    private var awaitingResponseOnset = true

    // MARK: - Tunables

    /// Gap in the input transcription stream after which the next fragment
    /// marks a new utterance
    private let utteranceGap: Double = 2.0
    /// The first transcript fragment arrives roughly this long after the
    /// speech itself started (ASR first-token delay)
    private let asrLagCompensation: Double = 1.0
    /// Gap between received chunks that marks the start of a new response
    private let receiveGap: Double = 1.0
    private let maxOnsets = 10
    private let onsetExpiry: Double = 30
    /// Adaptive EMA: react faster to large changes, slower to small ones
    private let alphaFast: Double = 0.3   // |sample - smoothed| > 1s
    private let alphaSlow: Double = 0.1
    /// Plausible range for a single utterance latency sample
    private let minSample: Double = 0.3
    private let maxSample: Double = 20

    // MARK: - Lifecycle

    /// Seed with an initial estimate so video delay isn't zero at startup.
    /// The EMA will adapt to real values as utterance samples arrive.
    func seedLatency(_ seconds: Double) {
        lock.withLock {
            guard !hasInitialSample else { return }
            smoothedLatency = seconds
            hasInitialSample = true
        }
    }

    /// Current smoothed latency estimate.
    func currentLatency() -> Double {
        lock.withLock { smoothedLatency }
    }

    /// Pause/resume gating. While paused no onsets are recorded and no samples
    /// are taken. Resuming clears stale matching state but keeps the EMA.
    func setPaused(_ paused: Bool) {
        lock.withLock {
            isPaused = paused
            if !paused {
                speechOnsets.removeAll()
                awaitingResponseOnset = true
            }
        }
    }

    /// Clear matching state but keep the EMA (seek/file-change).
    func resetForRecalibration() {
        lock.withLock {
            speechOnsets.removeAll()
            awaitingResponseOnset = true
        }
    }

    /// Full reset — zero everything (used when translation stops entirely).
    func reset() {
        lock.withLock {
            speechOnsets.removeAll()
            lastTranscriptTime = 0
            lastReceiveTime = 0
            awaitingResponseOnset = true
            isPaused = false
            smoothedLatency = 0
            hasInitialSample = false
        }
    }

    // MARK: - Measurement

    /// Feed every input transcription event at arrival time. The first
    /// fragment after a gap in the transcript stream marks a new utterance;
    /// the speech itself started roughly `asrLagCompensation` earlier.
    func noteInputTranscription() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            guard !isPaused else { return }
            if now - lastTranscriptTime > utteranceGap {
                speechOnsets.append(now - asrLagCompensation)
                if speechOnsets.count > maxOnsets {
                    speechOnsets.removeFirst()
                }
            }
            lastTranscriptTime = now
        }
    }

    /// The server finished a turn — the next received chunk starts a new response.
    func noteTurnComplete() {
        lock.withLock { awaitingResponseOnset = true }
    }

    /// Feed every received translated-audio chunk. `queuedDuration` is the
    /// playback backlog just before this chunk was enqueued. Returns the new
    /// smoothed latency when a per-utterance sample was taken, nil otherwise.
    func noteAudioReceived(queuedDuration: Double) -> Double? {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock {
            let isResponseOnset = awaitingResponseOnset || (now - lastReceiveTime > receiveGap)
            lastReceiveTime = now
            guard isResponseOnset else { return nil }
            awaitingResponseOnset = false
            guard !isPaused else { return nil }

            // Drop onsets too old to belong to this response
            while let first = speechOnsets.first, now - first > onsetExpiry {
                speechOnsets.removeFirst()
            }
            guard let onset = speechOnsets.first else { return nil }
            speechOnsets.removeFirst()

            let sample = now - onset + queuedDuration
            guard sample >= minSample && sample <= maxSample else {
                print("[LatencyTracker] Rejected sample \(String(format: "%.2f", sample))s")
                return nil
            }
            let smoothed = updateEMA(sample: sample)
            print("[LatencyTracker] Utterance sample: \(String(format: "%.2f", sample))s (queued: \(String(format: "%.2f", queuedDuration))s, onset backlog: \(speechOnsets.count)) → smoothed: \(String(format: "%.2f", smoothed))s")
            return smoothed
        }
    }

    // MARK: - Private

    /// Caller must hold `lock`.
    private func updateEMA(sample: Double) -> Double {
        if !hasInitialSample {
            smoothedLatency = sample
            hasInitialSample = true
        } else {
            let delta = abs(sample - smoothedLatency)
            let alpha = delta > 1.0 ? alphaFast : alphaSlow
            smoothedLatency = alpha * sample + (1 - alpha) * smoothedLatency
        }
        return smoothedLatency
    }
}
