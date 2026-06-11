import Foundation
import os


/// Measures round-trip latency of the translation pipeline (audio send → translated audio receive).
/// Thread-safe: can be called from any queue.
final class LatencyTracker: @unchecked Sendable {
    private var sendTimes: [CFAbsoluteTime] = []
    private var smoothedLatency: Double = 0
    private let alpha: Double = 0.1  // EMA smoothing factor
    private let maxSamples: Int = 200
    private let lock = OSAllocatedUnfairLock()

    /// Record that an audio chunk was sent to Gemini.
    func recordSend() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            sendTimes.append(now)
            if sendTimes.count > maxSamples {
                sendTimes.removeFirst(sendTimes.count - maxSamples)
            }
        }
    }

    /// Record that translated audio was received. Returns the smoothed latency estimate.
    func recordReceive() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock {
            guard !sendTimes.isEmpty else { return smoothedLatency }

            // Use a timestamp from roughly 1/3 into the buffer as a proxy for
            // the pipeline depth — not the newest (near-zero latency) or oldest (overestimate).
            let idx = sendTimes.count / 3
            let sample = now - sendTimes[idx]

            // Clamp to reasonable range (0.1s – 30s) to reject outliers
            guard sample > 0.1 && sample < 30 else { return smoothedLatency }

            smoothedLatency = alpha * sample + (1 - alpha) * smoothedLatency
            return smoothedLatency
        }
    }

    /// Current smoothed latency estimate.
    func currentLatency() -> Double {
        lock.withLock { smoothedLatency }
    }

    /// Reset all state (call when translation stops).
    func reset() {
        lock.withLock {
            sendTimes.removeAll()
            smoothedLatency = 0
        }
    }
}
