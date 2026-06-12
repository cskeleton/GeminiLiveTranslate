import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
import os

/// Plays back translated audio received from Gemini (24kHz, mono, Int16 PCM).
///
/// Incoming chunks land in a FIFO jitter buffer; the AudioQueue callback pulls
/// from the FIFO as buffers complete, filling with silence when nothing is
/// pending. Bursts from Gemini (faster than real-time) are never dropped, and
/// audio arriving while paused is kept for playback after resume.
final class AudioPlayer: @unchecked Sendable {
    private let sampleRate: Double = 24000
    private let channels: UInt32 = 1
    private let bitsPerSample: UInt32 = 16
    private let bytesPerSecond = 48_000           // 24kHz * 2 bytes, mono

    private let bufferCount = 4
    private let bufferCapacityBytes: UInt32 = 9600  // 200ms per AudioQueue buffer
    private let silenceFillBytes = 2400             // 50ms of silence when FIFO is empty
    private let maxPendingBytes = 60 * 48_000       // FIFO safety cap (60s)

    private let lock = OSAllocatedUnfairLock()
    // All state below is protected by `lock`. AudioQueue API calls happen
    // outside the lock except AudioQueueEnqueueBuffer (safe: it never invokes
    // the output callback synchronously).
    private var audioQueue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var pendingData = Data()
    /// Real (non-silence) audio bytes inside each currently-enqueued buffer.
    private var inFlightBytes: [AudioQueueBufferRef: Int] = [:]
    /// Buffers returned by the callback during AudioQueueReset, re-enqueued after.
    private var parkedBuffers: [AudioQueueBufferRef] = []
    private var isPlaying = false
    private var isPaused = false
    private var isResetting = false
    private var chunkCount = 0

    /// Duration of real audio waiting to be heard, in seconds:
    /// FIFO backlog plus audio already handed to the AudioQueue.
    var queuedDuration: Double {
        lock.lock()
        defer { lock.unlock() }
        let bytes = pendingData.count + inFlightBytes.values.reduce(0, +)
        return Double(bytes) / Double(bytesPerSecond)
    }

    init() {}

    deinit {
        stop()
    }

    /// Start the audio playback system
    func start() throws {
        lock.lock()
        if isPlaying {
            lock.unlock()
            return
        }
        lock.unlock()

        var streamDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerSample,
            mReserved: 0
        )

        var queueRef: AudioQueueRef?
        let status = AudioQueueNewOutput(
            &streamDesc,
            audioQueueCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &queueRef
        )

        guard status == noErr, let queue = queueRef else {
            throw PlayerError.failedToCreateQueue(status)
        }

        lock.lock()
        audioQueue = queue
        isPlaying = true
        isPaused = false
        lock.unlock()

        // Allocate buffers and prime them (with silence, FIFO is empty)
        for _ in 0..<bufferCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, bufferCapacityBytes, &buffer)
            if let buffer = buffer {
                lock.lock()
                buffers.append(buffer)
                fillAndEnqueue(buffer, queue: queue)
                lock.unlock()
            }
        }

        AudioQueueStart(queue, nil)
    }

    /// Stop playback and clean up
    func stop() {
        lock.lock()
        guard isPlaying else {
            lock.unlock()
            return
        }
        isPlaying = false
        isPaused = false
        pendingData.removeAll()
        inFlightBytes.removeAll()
        let queue = audioQueue
        audioQueue = nil
        lock.unlock()
        guard let queue = queue else { return }

        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)

        lock.lock()
        buffers.removeAll()
        parkedBuffers.removeAll()
        lock.unlock()
    }

    /// Pause playback — freezes the AudioQueue in place. Incoming audio keeps
    /// accumulating in the FIFO (it belongs to content the viewer hasn't lost).
    func pause() {
        lock.lock()
        guard isPlaying, !isPaused, let queue = audioQueue else {
            lock.unlock()
            return
        }
        isPaused = true
        lock.unlock()
        AudioQueuePause(queue)
        print("[AudioPlayer] Paused")
    }

    /// Resume playback from where it was paused.
    func resume() {
        lock.lock()
        guard isPlaying, isPaused, let queue = audioQueue else {
            lock.unlock()
            return
        }
        isPaused = false
        lock.unlock()
        AudioQueueStart(queue, nil)
        print("[AudioPlayer] Resumed")
    }

    /// Discard all buffered audio (seek/file-change). Keeps the queue running
    /// and preserves pause state.
    func flush() {
        lock.lock()
        guard isPlaying, let queue = audioQueue else {
            lock.unlock()
            return
        }
        pendingData.removeAll()
        isResetting = true
        lock.unlock()

        // Returns in-flight buffers via the output callback; the callback parks
        // them while isResetting so they aren't re-enqueued mid-reset.
        AudioQueueReset(queue)

        lock.lock()
        isResetting = false
        for buffer in parkedBuffers {
            fillAndEnqueue(buffer, queue: queue)
        }
        parkedBuffers.removeAll()
        lock.unlock()
        print("[AudioPlayer] Flushed")
    }

    /// Append translated audio to the FIFO. Never drops bursts; accepted while
    /// paused too (played after resume).
    func enqueueAudio(_ audioData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard isPlaying else { return }

        chunkCount += 1
        if chunkCount <= 5 || chunkCount % 100 == 0 {
            print("[AudioPlayer] Chunk #\(chunkCount): \(audioData.count) bytes, FIFO: \(pendingData.count) bytes")
        }

        pendingData.append(audioData)
        if pendingData.count > maxPendingBytes {
            let overflow = pendingData.count - maxPendingBytes
            pendingData.removeFirst(overflow & ~1)
            print("[AudioPlayer] FIFO overflow, dropped \(overflow) bytes")
        }
    }

    // MARK: - Buffer Filling

    /// Fill a buffer from the FIFO (or with silence) and hand it to the queue.
    /// Caller must hold `lock`.
    private func fillAndEnqueue(_ buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        var size = min(pendingData.count & ~1, capacity)
        if size > 0 {
            _ = pendingData.withUnsafeBytes { raw in
                memcpy(buffer.pointee.mAudioData, raw.baseAddress!, size)
            }
            pendingData.removeFirst(size)
            inFlightBytes[buffer] = size
        } else {
            // Keep the queue rolling with a short stretch of silence
            size = min(silenceFillBytes, capacity)
            memset(buffer.pointee.mAudioData, 0, size)
            inFlightBytes[buffer] = 0
        }
        buffer.pointee.mAudioDataByteSize = UInt32(size)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    // MARK: - Audio Queue Callback
    // Called on the AudioQueue's internal thread when a buffer finishes playing

    private let audioQueueCallback: AudioQueueOutputCallback = { (userData, queue, buffer) in
        guard let userData = userData else { return }
        let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()

        player.lock.lock()
        defer { player.lock.unlock() }
        player.inFlightBytes[buffer] = nil
        guard player.isPlaying else { return }
        if player.isResetting {
            player.parkedBuffers.append(buffer)
        } else {
            player.fillAndEnqueue(buffer, queue: queue)
        }
    }

    // MARK: - Errors

    enum PlayerError: Error, LocalizedError {
        case failedToCreateQueue(OSStatus)

        var errorDescription: String? {
            switch self {
            case .failedToCreateQueue(let status):
                return "Failed to create audio queue (status: \(status))"
            }
        }
    }
}
