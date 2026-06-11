import Foundation
import os

/// Measures round-trip latency of the translation pipeline (audio send → translated audio receive).
/// Uses sequence-number based precise per-chunk matching with adaptive EMA smoothing.
/// Thread-safe: can be called from any queue.
final class LatencyTracker: @unchecked Sendable {
    /// Pending send records, keyed by sequence number.
    private var pendingSends: [UInt64: CFAbsoluteTime] = [:]
    private var nextSeq: UInt64 = 0
    /// Smoothed network round-trip latency (does NOT include AudioQueue buffer depth)
    private var smoothedNetworkLatency: Double = 0
    private var hasInitialSample = false

    // Adaptive EMA: react faster to large changes, slower to small ones
    private let alphaFast: Double = 0.4   // Used when |sample - smoothed| > 1s
    private let alphaSlow: Double = 0.1   // Used for small fluctuations
    private let maxPending: Int = 500

    /// Seed with an initial estimate so video delay isn't zero at startup.
    /// Call before audio starts flowing. The EMA will quickly adapt to real values.
    func seedLatency(_ seconds: Double) {
        lock.withLock {
            guard !hasInitialSample else { return }
            smoothedNetworkLatency = seconds
            hasInitialSample = true
        }
    }

    private let lock = OSAllocatedUnfairLock()

    /// Record that an audio chunk was sent to Gemini. Returns the assigned sequence number.
    @discardableResult
    func recordSend() -> UInt64 {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock {
            let seq = nextSeq
            nextSeq += 1
            pendingSends[seq] = now
            // Trim oldest entries if too many pending
            if pendingSends.count > maxPending {
                let sorted = pendingSends.sorted { $0.key < $1.key }
                let toRemove = sorted.prefix(pendingSends.count - maxPending)
                for entry in toRemove {
                    pendingSends.removeValue(forKey: entry.key)
                }
            }
            return seq
        }
    }

    /// Record that translated audio was received, matched to a specific send sequence.
    /// Returns the smoothed latency estimate.
    func recordReceive(sendSeq: UInt64) -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock {
            // Remove the matched send and compute precise round-trip
            guard let sendTime = pendingSends.removeValue(forKey: sendSeq) else {
                guard let oldest = pendingSends.min(by: { $0.key < $1.key }) else {
                    return smoothedNetworkLatency
                }
                pendingSends.removeValue(forKey: oldest.key)
                return updateEMA(sample: now - oldest.value)
            }
            return updateEMA(sample: now - sendTime)
        }
    }

    /// Record receive without a specific sequence (fallback). Uses oldest pending send.
    func recordReceive() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock {
            guard let oldest = pendingSends.min(by: { $0.key < $1.key }) else {
                return smoothedNetworkLatency
            }
            pendingSends.removeValue(forKey: oldest.key)
            return updateEMA(sample: now - oldest.value)
        }
    }

    /// Current smoothed latency estimate, plus optional extra (e.g. AudioQueue buffer depth).
    func currentLatency(extra: Double = 0) -> Double {
        lock.withLock { smoothedNetworkLatency + extra }
    }

    /// Reset pending sends but keep the last latency as seed for recalibration.
    /// Used on resume/seek so the video delay doesn't jump to zero.
    func resetForRecalibration() {
        lock.withLock {
            pendingSends.removeAll()
            nextSeq = 0
            // Keep smoothedNetworkLatency and hasInitialSample — EMA will converge
            // from the last known value as new samples arrive
        }
    }

    /// Full reset — zero everything (used when translation stops entirely).
    func reset() {
        lock.withLock {
            pendingSends.removeAll()
            nextSeq = 0
            smoothedNetworkLatency = 0
            hasInitialSample = false
        }
    }

    // MARK: - Private

    private func updateEMA(sample: Double) -> Double {
        // Clamp to reasonable range (0.05s – 30s) to reject outliers
        guard sample > 0.05 && sample < 30 else { return smoothedNetworkLatency }

        if !hasInitialSample {
            // First sample: initialize directly
            smoothedNetworkLatency = sample
            hasInitialSample = true
        } else {
            // Adaptive alpha: react faster to large changes
            let delta = abs(sample - smoothedNetworkLatency)
            let alpha = delta > 1.0 ? alphaFast : alphaSlow
            smoothedNetworkLatency = alpha * sample + (1 - alpha) * smoothedNetworkLatency
        }
        return smoothedNetworkLatency
    }
}
