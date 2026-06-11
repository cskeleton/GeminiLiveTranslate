import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox

/// Plays back translated audio received from Gemini (24kHz, mono, Int16 PCM)
final class AudioPlayer: @unchecked Sendable {
    private var audioQueue: AudioQueueRef?
    private var isPlaying = false
    private let sampleRate: Double = 24000
    private let channels: UInt32 = 1
    private let bitsPerSample: UInt32 = 16
    private let bufferCount: Int = 6
    private var buffers: [AudioQueueBufferRef] = []

    private var chunkCount = 0

    /// Number of buffers currently filled and queued for playback (0...bufferCount).
    var filledBufferCount: Int {
        buffers.filter { $0.pointee.mAudioDataByteSize > 0 }.count
    }

    /// Estimated playback latency from buffer depth, in seconds.
    var bufferLatency: Double {
        Double(filledBufferCount) * 0.5  // Each buffer is 500ms
    }

    init() {}

    deinit {
        stop()
    }

    /// Start the audio playback system
    func start() throws {
        guard !isPlaying else { return }

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

        let status = AudioQueueNewOutput(
            &streamDesc,
            audioQueueCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &audioQueue
        )

        guard status == noErr, let queue = audioQueue else {
            throw PlayerError.failedToCreateQueue(status)
        }

        // Allocate buffers — 500ms each
        let bufferSize = UInt32(sampleRate * 0.5 * Double(channels) * Double(bitsPerSample / 8))
        for _ in 0..<bufferCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, bufferSize, &buffer)
            if let buffer = buffer {
                // Prime with empty buffer so the queue can start
                buffer.pointee.mAudioDataByteSize = 0
                AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
                buffers.append(buffer)
            }
        }

        isPlaying = true
        AudioQueueStart(queue, nil)
    }

    /// Stop playback and clean up
    func stop() {
        guard isPlaying else { return }
        isPlaying = false

        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        audioQueue = nil
        buffers.removeAll()
    }

    /// Flush all buffered audio (used on pause/seek to prevent desync)
    func flush() {
        guard isPlaying, let queue = audioQueue else { return }
        // Stop the queue, reset all buffers, restart
        AudioQueueStop(queue, true)
        for buffer in buffers {
            buffer.pointee.mAudioDataByteSize = 0
        }
        // Re-prime and restart
        for buffer in buffers {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
        AudioQueueStart(queue, nil)
        print("[AudioPlayer] Flushed all buffers")
    }

    /// Enqueue translated audio data for playback
    func enqueueAudio(_ audioData: Data) {
        guard isPlaying, let queue = audioQueue else { return }

        chunkCount += 1
        if chunkCount <= 5 || chunkCount % 100 == 0 {
            print("[AudioPlayer] Chunk #\(chunkCount): \(audioData.count) bytes")
        }

        // Find an available buffer (mAudioDataByteSize == 0 means it's done playing)
        guard let buffer = buffers.first(where: { $0.pointee.mAudioDataByteSize == 0 }) else {
            // All buffers still playing — skip this chunk (rare, means we're producing faster than playing)
            return
        }

        let dataSize = min(audioData.count, Int(buffer.pointee.mAudioDataBytesCapacity))
        _ = audioData.withUnsafeBytes { rawBuffer in
            memcpy(buffer.pointee.mAudioData, rawBuffer.baseAddress!, dataSize)
        }
        buffer.pointee.mAudioDataByteSize = UInt32(dataSize)

        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    // MARK: - Audio Queue Callback
    // Called on the real-time audio thread when a buffer finishes playing

    private let audioQueueCallback: AudioQueueOutputCallback = { (userData, queue, buffer) in
        guard let userData = userData else { return }
        let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()

        // Mark buffer as available for reuse
        buffer.pointee.mAudioDataByteSize = 0

        // Re-enqueue for next audio chunk
        if player.isPlaying {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
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
