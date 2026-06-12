import Foundation
import ScreenCaptureKit
import AVFoundation

/// Main translation engine that coordinates audio capture, Gemini API, playback, and subtitle output
@MainActor
class TranslationEngine {
    private var audioCapture: SystemAudioCapture?
    private var geminiSocket: GeminiWebSocket?
    private var audioPlayer: AudioPlayer?
    private var latencyTracker: LatencyTracker?
    private var webSocketServer: WebSocketServer?

    private let apiKey: String
    private let targetLanguageCode: String
    private let showOverlay: Bool
    private let writeToFile: Bool
    private let subtitleFontSize: Double

    private var subtitleFileHandle: FileHandle?
    private var subtitleFileURL: URL?

    private(set) var isRunning = false
    private var isTransitioning = false  // Prevents concurrent start/stop

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
        guard !isRunning, !isTransitioning else { return }
        isTransitioning = true

        do {
            // 1. Set up subtitle file if enabled
            if writeToFile {
                setupSubtitleFile()
            }

            // 2. Create audio player first (before callbacks reference it)
            let player = AudioPlayer()
            try player.start()
            audioPlayer = player

            // 3. Latency tracker — one EMA sample per utterance
            let tracker = LatencyTracker()
            // Conservative estimate so video delay isn't zero before the first sample
            tracker.seedLatency(2.0)
            latencyTracker = tracker
            AppState.shared.currentLatency = tracker.currentLatency()

            // 4. Start IINA sync server if enabled (before the socket, so the
            // receive path below can capture it directly)
            var startedServer: WebSocketServer?
            if AppState.shared.enableIINASync {
                let server = WebSocketServer(port: UInt16(AppState.shared.iinaSyncPort))
                do {
                    // Seek/file-change: drop stale audio, keep the EMA
                    server.onFlush = {
                        player.flush()
                        tracker.resetForRecalibration()
                    }
                    // Pause: freeze AudioQueue in place, stop sampling
                    server.onPause = {
                        player.pause()
                        tracker.setPaused(true)
                    }
                    // Resume: unfreeze; tracker drops stale onsets, keeps EMA
                    server.onResume = {
                        player.resume()
                        tracker.setPaused(false)
                    }
                    try server.start()
                    server.startBroadcasting()
                    // Publish the seed so the plugin applies an initial delay right away
                    server.updateLatency(Self.latencyJSON(tracker.currentLatency()))
                    webSocketServer = server
                    startedServer = server
                    AppState.shared.iinaSyncServerRunning = true
                } catch {
                    AppState.shared.errorMessage = "IINA sync server failed: \(error.localizedDescription)"
                    // Translation continues without sync — non-fatal
                }
            }
            let serverRef = startedServer

            // 5. Connect to Gemini API
            let socket = GeminiWebSocket(apiKey: apiKey, targetLanguageCode: targetLanguageCode)

            socket.onInputTranscription = { [weak self] text, langCode in
                // Anchor utterance-start detection to the server's ASR stream
                tracker.noteInputTranscription()
                // Delay subtitle to match audio playback (queued backlog)
                let delay = player.queuedDuration
                Task { @MainActor [weak self] in
                    if delay > 0.05 {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    self?.handleInputTranscription(text, langCode: langCode)
                }
            }

            socket.onOutputTranscription = { [weak self] text, langCode in
                let delay = player.queuedDuration
                Task { @MainActor [weak self] in
                    if delay > 0.05 {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    self?.handleOutputTranscription(text, langCode: langCode)
                }
            }

            // Receive path runs off the main actor; player/tracker/server are thread-safe.
            // The latency only changes when a per-utterance sample is taken.
            socket.onAudioData = { audioData in
                let queuedBefore = player.queuedDuration
                player.enqueueAudio(audioData)
                if let latency = tracker.noteAudioReceived(queuedDuration: queuedBefore) {
                    serverRef?.updateLatency(Self.latencyJSON(latency))
                    Task { @MainActor in
                        AppState.shared.currentLatency = latency
                    }
                }
            }

            socket.onTurnComplete = {
                tracker.noteTurnComplete()
            }

            socket.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    player.stop()
                    AppState.shared.errorMessage = error.localizedDescription
                    AppState.shared.statusMessage = "Error"
                    await self?.forceStop()
                }
            }

            geminiSocket = socket
            try await socket.connect()

            // 6. Start audio capture
            let capture = SystemAudioCapture()
            capture.onAudioChunk = { [weak socket] pcmData in
                socket?.sendAudioChunk(pcmData)
            }
            capture.onError = { [weak self] error in
                Task { @MainActor in
                    AppState.shared.errorMessage = "Audio capture error: \(error.localizedDescription)"
                    await self?.forceStop()
                }
            }
            try await capture.startCapture()
            audioCapture = capture

            isRunning = true
            isTransitioning = false

            AppState.shared.isTranslating = true
            AppState.shared.statusMessage = "Translating…"
            NotificationCenter.default.post(name: .translationStarted, object: nil)

        } catch {
            isTransitioning = false
            // Clean up anything that was partially started
            await forceStop()
            throw error
        }
    }

    /// Stop the translation pipeline
    func stop() async {
        guard isRunning, !isTransitioning else { return }
        isTransitioning = true

        await forceStop()
    }

    /// Force stop regardless of state (used for error recovery)
    private func forceStop() async {
        isRunning = false

        // Disconnect socket first (stops audio data flow)
        geminiSocket?.disconnect()
        geminiSocket = nil

        // Stop audio capture
        await audioCapture?.stopCapture()
        audioCapture = nil

        // Stop playback last (finish playing buffered audio)
        audioPlayer?.stop()
        audioPlayer = nil

        closeSubtitleFile()

        // Stop IINA sync server
        webSocketServer?.broadcast("{\"latency\":0,\"isTranslating\":false}")
        webSocketServer?.stop()
        webSocketServer = nil
        latencyTracker?.reset()
        latencyTracker = nil
        AppState.shared.currentLatency = 0
        AppState.shared.iinaSyncServerRunning = false

        isTransitioning = false

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

    nonisolated private static func latencyJSON(_ latency: Double) -> String {
        "{\"latency\":\(String(format: "%.2f", latency)),\"isTranslating\":true}"
    }

    private func languageName(for code: String) -> String {
        supportedLanguages.first { $0.code == code }?.name ?? code
    }
}
