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
    private let bufferCount: Int = 3
    private var buffers: [AudioQueueBufferRef] = []

    /// Callback when audio finishes playing (all buffers drained)
    var onPlaybackFinished: (() -> Void)?

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

        // Allocate buffers — must be large enough for Gemini's chunks (~12000 bytes / 250ms)
        let bufferSize = UInt32(sampleRate * 0.5 * Double(channels) * Double(bitsPerSample / 8)) // 500ms buffer
        for _ in 0..<bufferCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, bufferSize, &buffer)
            if let buffer = buffer {
                buffers.append(buffer)
            }
        }

        // Prime the queue with empty buffers
        for buffer in buffers {
            buffer.pointee.mAudioDataByteSize = 0
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
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

    private var chunkCount = 0

    /// Enqueue translated audio data for playback
    /// - Parameter audioData: Raw PCM 24kHz mono Int16 audio data from Gemini
    func enqueueAudio(_ audioData: Data) {
        guard isPlaying, let queue = audioQueue else {
            print("[AudioPlayer] ⚠️ Not playing, dropping \(audioData.count) bytes")
            return
        }

        chunkCount += 1
        if chunkCount <= 3 || chunkCount % 50 == 0 {
            print("[AudioPlayer] Chunk #\(chunkCount): \(audioData.count) bytes")
        }

        // Find an available buffer
        guard let buffer = buffers.first(where: { $0.pointee.mAudioDataByteSize == 0 }) else {
            if chunkCount <= 3 {
                print("[AudioPlayer] ⚠️ All buffers busy, dropping chunk")
            }
            return // All buffers busy, skip this chunk
        }

        let dataSize = min(audioData.count, Int(buffer.pointee.mAudioDataBytesCapacity))
        _ = audioData.withUnsafeBytes { rawBuffer in
            memcpy(buffer.pointee.mAudioData, rawBuffer.baseAddress!, dataSize)
        }
        buffer.pointee.mAudioDataByteSize = UInt32(dataSize)

        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    // MARK: - Audio Queue Callback

    private let audioQueueCallback: AudioQueueOutputCallback = { (userData, queue, buffer) in
        guard let userData = userData else { return }
        let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()

        // Mark buffer as available for reuse
        buffer.pointee.mAudioDataByteSize = 0

        // Re-enqueue the buffer for more audio
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
