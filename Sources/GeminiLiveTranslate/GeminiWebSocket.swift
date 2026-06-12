import Foundation

/// Handles WebSocket communication with the Gemini Live Translate API
final class GeminiWebSocket: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate, @unchecked Sendable {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let apiKey: String
    private let targetLanguageCode: String
    private let callbackQueue = DispatchQueue(label: "com.gemini.websocket.callbacks", qos: .userInitiated)
    private var isConnected = false
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimeout: DispatchWorkItem?

    var onInputTranscription: ((String, String) -> Void)?
    var onOutputTranscription: ((String, String) -> Void)?
    var onAudioData: ((Data) -> Void)?
    /// Fired when the server marks a turn/generation as complete — the next
    /// audio chunk belongs to a new response.
    var onTurnComplete: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(apiKey: String, targetLanguageCode: String) {
        self.apiKey = apiKey
        self.targetLanguageCode = targetLanguageCode
        super.init()
    }

    /// Connect to the Gemini Live Translate API
    func connect() async throws {
        guard !apiKey.isEmpty else {
            throw ConnectionError.noAPIKey
        }

        let maskedKey = String(apiKey.prefix(8)) + "..." + String(apiKey.suffix(4))
        log("Connecting with key: \(maskedKey)")

        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            log("ERROR: Invalid URL")
            throw ConnectionError.invalidURL
        }

        log("URL: wss://generativelanguage.googleapis.com/ws/...BidiGenerateContent?key=***")

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: url)

        log("Resuming WebSocket task...")
        webSocketTask?.resume()

        // Wait for didOpenWithProtocol to fire and setup to complete
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setupContinuation = continuation

            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self, self.setupContinuation != nil else { return }
                self.log("ERROR: Connection timed out (15s)")
                self.setupContinuation = nil
                self.disconnect()
                continuation.resume(throwing: ConnectionError.timeout)
            }
            self.connectionTimeout = timeout
            callbackQueue.asyncAfter(deadline: .now() + 15, execute: timeout)
        }
    }

    func disconnect() {
        connectionTimeout?.cancel()
        connectionTimeout = nil
        setupContinuation = nil
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        log("Disconnected")
    }

    private func sendSetupMessage() {
        let setup: [String: Any] = [
            "setup": [
                "model": "models/gemini-3.5-live-translate-preview",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "translationConfig": [
                        "targetLanguageCode": targetLanguageCode,
                        "echoTargetLanguage": true
                    ]
                ],
                "inputAudioTranscription": [:] as [String: Any],
                "outputAudioTranscription": [:] as [String: Any]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: setup),
              let jsonString = String(data: data, encoding: .utf8) else {
            log("ERROR: Failed to serialize setup message")
            setupContinuation?.resume(throwing: ConnectionError.setupFailed)
            setupContinuation = nil
            return
        }

        log("Sending setup message...")
        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("ERROR: Setup send failed: \(error.localizedDescription)")
                self.setupContinuation?.resume(throwing: error)
                self.setupContinuation = nil
            } else {
                self.log("Setup message sent, waiting for server response...")
                // Don't resume yet - wait for the first receive (setupComplete or error)
                self.waitForSetupAck()
            }
        }
    }

    private func waitForSetupAck() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? "<binary>"
                @unknown default: text = "<unknown>"
                }
                self.log("Server response: \(text.prefix(200))")

                // Check if it's an error response
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let error = json["error"] as? [String: Any] {
                        let msg = error["message"] as? String ?? "Unknown server error"
                        let code = error["code"] as? Int ?? 0
                        self.log("ERROR: Server returned error \(code): \(msg)")
                        self.setupContinuation?.resume(throwing: ConnectionError.serverError(code, msg))
                        self.setupContinuation = nil
                        return
                    }
                }

                // Setup succeeded
                self.log("Connection established!")
                self.isConnected = true
                self.connectionTimeout?.cancel()
                self.connectionTimeout = nil
                self.setupContinuation?.resume()
                self.setupContinuation = nil

                // Now start the continuous receive loop
                self.receiveMessage()

                // Also handle this first message (might contain data)
                self.handleMessage(text)

            case .failure(let error):
                self.log("ERROR: First receive failed: \(error.localizedDescription)")
                self.setupContinuation?.resume(throwing: error)
                self.setupContinuation = nil
            }
        }
    }

    func sendAudioChunk(_ pcmData: Data) {
        guard isConnected else { return }

        let base64Audio = pcmData.base64EncodedString()
        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": base64Audio,
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                self?.log("ERROR: Audio send failed: \(error.localizedDescription)")
                self?.callbackQueue.async {
                    self?.onError?(error)
                }
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()

            case .failure(let error):
                if self.isConnected {
                    self.isConnected = false
                    self.log("ERROR: Receive failed: \(error.localizedDescription)")
                    self.callbackQueue.async {
                        self.onError?(ConnectionError.socketError(error.localizedDescription))
                    }
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if json["setupComplete"] != nil {
            log("Setup complete acknowledged by server")
            return
        }

        if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown error"
            log("Server error in message: \(msg)")
            callbackQueue.async { [weak self] in
                self?.onError?(ConnectionError.serverError(0, msg))
            }
            return
        }

        // Server uses camelCase in responses
        guard let serverContent = json["serverContent"] as? [String: Any] else {
            return
        }

        if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String {
            let langCode = inputTranscription["languageCode"] as? String ?? ""
            callbackQueue.async { [weak self] in
                self?.onInputTranscription?(text, langCode)
            }
        }

        if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String {
            let langCode = outputTranscription["languageCode"] as? String ?? ""
            callbackQueue.async { [weak self] in
                self?.onOutputTranscription?(text, langCode)
            }
        }

        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let base64Data = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64Data) {
                    callbackQueue.async { [weak self] in
                        self?.onAudioData?(audioData)
                    }
                }
            }
        }

        if (serverContent["turnComplete"] as? Bool) == true
            || (serverContent["generationComplete"] as? Bool) == true {
            callbackQueue.async { [weak self] in
                self?.onTurnComplete?()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        log("WebSocket opened (protocol: \(proto ?? "none"))")
        sendSetupMessage()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        log("WebSocket closed: code=\(closeCode.rawValue), reason=\(reasonStr)")
        isConnected = false
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        log("Auth challenge: \(challenge.protectionSpace.authenticationMethod)")
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let timestamp = DateFormatter.logTimestamp.string(from: Date())
        print("[\(timestamp)] [GeminiWS] \(message)")
    }

    // MARK: - Errors

    enum ConnectionError: Error, LocalizedError {
        case noAPIKey
        case invalidURL
        case timeout
        case setupFailed
        case serverError(Int, String)
        case socketError(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "API key not set. Please enter your Gemini API key in Settings."
            case .invalidURL:
                return "Invalid API URL"
            case .timeout:
                return "Connection timed out (15s). Check your network and API key."
            case .setupFailed:
                return "Failed to create setup message"
            case .serverError(let code, let msg):
                return "Gemini server error (\(code)): \(msg)"
            case .socketError(let msg):
                return "WebSocket error: \(msg)"
            }
        }
    }
}

private extension DateFormatter {
    static let logTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
