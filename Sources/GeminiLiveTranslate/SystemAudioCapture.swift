import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
@preconcurrency import AVFoundation

/// Captures system audio using ScreenCaptureKit and provides PCM 16kHz mono Int16 data
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var audioConverter: AVAudioConverter?

    /// Callback when a PCM audio chunk is ready (16kHz, mono, Int16)
    var onAudioChunk: ((Data) -> Void)?
    /// Callback when an error occurs
    var onError: ((Error) -> Void)?

    private(set) var isCapturing = false

    // Target format for Gemini: 16kHz, mono, Int16
    private let targetSampleRate: Double = 16000
    private let targetFormat: AVAudioFormat

    override init() {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
        super.init()
    }

    /// Start capturing system audio
    func startCapture() async throws {
        guard !isCapturing else { return }

        // Get available content (displays and apps)
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )

        guard let display = content.displays.first else {
            throw CaptureError.noDisplayFound
        }

        // Create a content filter that captures all system audio
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        // Configure the stream for audio-only capture
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000  // System audio sample rate
        config.channelCount = 2    // Stereo

        // We don't need video, but SCStream requires some video config
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimal video
        config.queueDepth = 1

        // Create and start the stream
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.gemini.audioCapture"))
        try await newStream.startCapture()
        stream = newStream
        isCapturing = true
    }

    /// Stop capturing system audio
    func stopCapture() async {
        guard isCapturing else { return }
        try? await stream?.stopCapture()
        stream = nil
        isCapturing = false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        // Convert CMSampleBuffer to PCM data and send
        if let pcmData = convertToPCM16kHz(sampleBuffer) {
            onAudioChunk?(pcmData)
        }
    }

    // MARK: - Audio Conversion

    /// Convert a CMSampleBuffer (48kHz stereo Float32) to 16kHz mono Int16 PCM data
    private func convertToPCM16kHz(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        let asbd = asbdPtr.pointee

        // Create source format from the ASBD
        guard let sourceFormat = withUnsafePointer(to: asbd, { ptr in
            AVAudioFormat(streamDescription: ptr)
        }) else {
            return nil
        }

        // Get the audio data from the CMSampleBuffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)

        guard let dataPointer = dataPointer else { return nil }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return nil
        }
        sourceBuffer.frameLength = frameCount

        // Copy audio data into the source buffer
        let totalBytes = Int(frameCount) * Int(asbd.mBytesPerFrame)
        let bytesToCopy = min(totalBytes, dataLength)

        if sourceFormat.isInterleaved {
            if let channelData = sourceBuffer.int16ChannelData {
                memcpy(channelData[0], dataPointer, bytesToCopy)
            } else if let floatChannelData = sourceBuffer.floatChannelData {
                memcpy(floatChannelData[0], dataPointer, bytesToCopy)
            }
        } else {
            // Non-interleaved: copy each channel separately
            let bytesPerChannel = Int(frameCount) * Int(asbd.mBytesPerPacket / asbd.mChannelsPerFrame)
            for ch in 0..<Int(asbd.mChannelsPerFrame) {
                if let floatChannelData = sourceBuffer.floatChannelData?[ch] {
                    let offset = ch * bytesPerChannel
                    memcpy(floatChannelData, dataPointer.advanced(by: offset), bytesPerChannel)
                }
            }
        }

        // Create or update converter
        if audioConverter == nil || audioConverter?.inputFormat != sourceFormat {
            audioConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }

        guard let converter = audioConverter else { return nil }

        // Calculate output frame count (resampled)
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status == .haveData, conversionError == nil else { return nil }

        // Convert the output buffer to Data
        let frames = Int(outputBuffer.frameLength)
        guard frames > 0 else { return nil }

        if let channelData = outputBuffer.int16ChannelData {
            let dataSize = frames * MemoryLayout<Int16>.size
            return Data(bytes: channelData[0], count: dataSize)
        }

        return nil
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturing = false
        onError?(error)
    }

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case noDisplayFound
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .noDisplayFound:
                return "No display found for audio capture"
            case .conversionFailed:
                return "Failed to convert audio format"
            }
        }
    }
}
