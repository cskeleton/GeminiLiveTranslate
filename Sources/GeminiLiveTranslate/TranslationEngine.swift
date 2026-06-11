import Foundation
import ScreenCaptureKit
import AVFoundation

/// Main translation engine that coordinates audio capture, Gemini API, playback, and subtitle output
@MainActor
class TranslationEngine {
    private var audioCapture: SystemAudioCapture?
    private var geminiSocket: GeminiWebSocket?
    private var audioPlayer: AudioPlayer?

    private let apiKey: String
    private let targetLanguageCode: String
    private let showOverlay: Bool
    private let writeToFile: Bool
    private let subtitleFontSize: Double

    private var subtitleFileHandle: FileHandle?
    private var subtitleFileURL: URL?

    private(set) var isRunning = false

    init(apiKey: String, targetLanguageCode: String, showOverlay: Bool,
         writeToFile: Bool, subtitleFontSize: Double) {
        self.apiKey = apiKey
        self.targetLanguageCode = targetLanguageCode
        self.showOverlay = showOverlay
        self.writeToFile = writeToFile
        self.subtitleFontSize = subtitleFontSize
    }

    /// Start the translation pipeline
    func start() async throws {
        guard !isRunning else { return }

        // 1. Set up subtitle file if enabled
        if writeToFile {
            setupSubtitleFile()
        }

        // 2. Create audio player first (before callbacks reference it)
        let player = AudioPlayer()
        try player.start()
        audioPlayer = player

        // 3. Connect to Gemini API
        let socket = GeminiWebSocket(apiKey: apiKey, targetLanguageCode: targetLanguageCode)

        socket.onInputTranscription = { [weak self] text, langCode in
            Task { @MainActor [weak self] in
                self?.handleInputTranscription(text, langCode: langCode)
            }
        }

        socket.onOutputTranscription = { [weak self] text, langCode in
            Task { @MainActor [weak self] in
                self?.handleOutputTranscription(text, langCode: langCode)
            }
        }

        // Audio playback is thread-safe (AudioQueue uses its own thread)
        // Capture player directly — don't go through @MainActor self
        socket.onAudioData = { audioData in
            player.enqueueAudio(audioData)
        }

        socket.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                player.stop()
                AppState.shared.errorMessage = error.localizedDescription
                AppState.shared.statusMessage = "Error"
            }
        }

        geminiSocket = socket
        try await socket.connect()

        // 3. Start audio capture
        let capture = SystemAudioCapture()
        capture.onAudioChunk = { [weak self] pcmData in
            Task { @MainActor in
                self?.geminiSocket?.sendAudioChunk(pcmData)
            }
        }
        capture.onError = { [weak self] error in
            Task { @MainActor in
                AppState.shared.errorMessage = "Audio capture error: \(error.localizedDescription)"
                await self?.stop()
            }
        }
        try await capture.startCapture()
        audioCapture = capture

        isRunning = true

        AppState.shared.isTranslating = true
        AppState.shared.statusMessage = "Translating…"
        NotificationCenter.default.post(name: .translationStarted, object: nil)
    }

    /// Stop the translation pipeline
    func stop() async {
        guard isRunning else { return }
        isRunning = false

        await audioCapture?.stopCapture()
        audioCapture = nil

        geminiSocket?.disconnect()
        geminiSocket = nil

        audioPlayer?.stop()
        audioPlayer = nil

        closeSubtitleFile()

        AppState.shared.isTranslating = false
        AppState.shared.statusMessage = "Ready"
        AppState.shared.resetSubtitles()
        NotificationCenter.default.post(name: .translationStopped, object: nil)
    }

    // MARK: - Transcription Handling

    private func handleInputTranscription(_ text: String, langCode: String) {
        let langName = languageName(for: langCode)

        AppState.shared.lastInputText = text
        if !langCode.isEmpty {
            AppState.shared.detectedLanguage = langName
        }

        if showOverlay {
            NotificationCenter.default.post(name: .subtitleUpdated, object: nil, userInfo: [
                "inputText": text,
                "inputLang": langName
            ])
        }

        if writeToFile {
            writeSubtitleLine("[\(langName)] \(text)")
        }
    }

    private func handleOutputTranscription(_ text: String, langCode: String) {
        let langName = languageName(for: langCode)

        AppState.shared.lastOutputText = text

        if showOverlay {
            NotificationCenter.default.post(name: .subtitleUpdated, object: nil, userInfo: [
                "outputText": text,
                "outputLang": langName
            ])
        }

        if writeToFile {
            writeSubtitleLine("[\(langName)] \(text)")
        }
    }

    // MARK: - File Output

    private func setupSubtitleFile() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "subtitles_\(timestamp).txt"

        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return
        }

        subtitleFileURL = downloadsURL.appendingPathComponent(fileName)

        guard let url = subtitleFileURL else { return }

        let header = "Gemini Live Translate - Subtitles\n"
            + "Started: \(Date())\n"
            + "Target Language: \(targetLanguageCode)\n"
            + String(repeating: "─", count: 50) + "\n\n"

        try? header.write(to: url, atomically: true, encoding: .utf8)

        subtitleFileHandle = try? FileHandle(forWritingTo: url)
        subtitleFileHandle?.seekToEndOfFile()
    }

    private func writeSubtitleLine(_ line: String) {
        guard let handle = subtitleFileHandle else { return }
        let timestamped = "[\(timestampString())] \(line)\n"
        if let data = timestamped.data(using: .utf8) {
            handle.write(data)
        }
    }

    private func closeSubtitleFile() {
        if let handle = subtitleFileHandle {
            let footer = "\n" + String(repeating: "─", count: 50) + "\n"
                + "Ended: \(Date())\n"
            if let data = footer.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        }
        subtitleFileHandle = nil
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    // MARK: - Helpers

    private func languageName(for code: String) -> String {
        supportedLanguages.first { $0.code == code }?.name ?? code
    }
}
