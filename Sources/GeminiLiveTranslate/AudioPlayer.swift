import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox

/// Plays back translated audio received from Gemini (24kHz, mono, Int16 PCM)
/// Uses a ring of AudioQueue buffers with pre-buffering to avoid gaps
final class AudioPlayer: @unchecked Sendable {
    private var audioQueue: AudioQueueRef?
    private var isPlaying = false
    private let sampleRate: Double = 24000
    private let channels: UInt32 = 1
    private let bitsPerSample: UInt32 = 16
    private let bufferCount: Int = 8  // More buffers = more resilience to jitter
    private var buffers: [AudioQueueBufferRef] = []
    private let bufferQueue = DispatchQueue(label: "com.gemini.audioplayer.buffers")

    // Pre-buffering: wait for this many chunks before starting playback
    private let preBufferCount = 4
    private var chunksReceived = 0
    private var playbackStarted = false
    private var pendingAudio: [Data] = []

    private var chunkCount = 0

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

        // Allocate buffers — 500ms each, enough for any Gemini chunk
        let bufferSize = UInt32(sampleRate * 0.5 * Double(channels) * Double(bitsPerSample / 8))
        for _ in 0..<bufferCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, bufferSize, &buffer)
            if let buffer = buffer {
                buffers.append(buffer)
            }
        }

        isPlaying = true
        // Don't start the queue yet — wait for pre-buffer
    }

    /// Stop playback and clean up
    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        playbackStarted = false
        chunksReceived = 0
        pendingAudio.removeAll()

        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        audioQueue = nil
        buffers.removeAll()
    }

    /// Enqueue translated audio data for playback
    func enqueueAudio(_ audioData: Data) {
        guard isPlaying else { return }

        chunkCount += 1
        if chunkCount <= 5 || chunkCount % 100 == 0 {
            print("[AudioPlayer] Chunk #\(chunkCount): \(audioData.count) bytes")
        }

        bufferQueue.async { [weak self] in
            guard let self = self else { return }

            if !self.playbackStarted {
                // Pre-buffer phase: collect chunks before starting playback
                self.pendingAudio.append(audioData)
                self.chunksReceived += 1

                if self.chunksReceived >= self.preBufferCount {
                    print("[AudioPlayer] Pre-buffered \(self.chunksReceived) chunks, starting playback")
                    self.playbackStarted = true

                    // Flush all pending audio into buffers and start the queue
                    for chunk in self.pendingAudio {
                        self.enqueueToBuffer(chunk)
                    }
                    self.pendingAudio.removeAll()

                    if let queue = self.audioQueue {
                        AudioQueueStart(queue, nil)
                    }
                }
            } else {
                // Normal playback: enqueue directly
                self.enqueueToBuffer(audioData)
            }
        }
    }

    /// Internal: copy audio data into an available buffer and enqueue it
    private func enqueueToBuffer(_ audioData: Data) {
        guard let queue = audioQueue else { return }

        // Find an available buffer (mAudioDataByteSize == 0 means it's been consumed)
        guard let buffer = buffers.first(where: { $0.pointee.mAudioDataByteSize == 0 }) else {
            // All buffers busy — this is normal during steady-state playback
            // The callback will re-enqueue buffers as they finish playing
            if chunkCount <= 5 {
                print("[AudioPlayer] ⚠️ All buffers busy, dropping chunk")
            }
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
