import Foundation
import SwiftUI

/// Language definitions for the Gemini Live Translate API
struct Language: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

/// All languages supported by Gemini Live Translate
let supportedLanguages: [Language] = [
    Language(code: "en", name: "English"),
    Language(code: "zh-Hans", name: "Chinese (Simplified)"),
    Language(code: "zh-Hant", name: "Chinese (Traditional)"),
    Language(code: "ja", name: "Japanese"),
    Language(code: "ko", name: "Korean"),
    Language(code: "es", name: "Spanish"),
    Language(code: "fr", name: "French"),
    Language(code: "de", name: "German"),
    Language(code: "it", name: "Italian"),
    Language(code: "pt-BR", name: "Portuguese (Brazil)"),
    Language(code: "pt-PT", name: "Portuguese (Portugal)"),
    Language(code: "ru", name: "Russian"),
    Language(code: "ar", name: "Arabic"),
    Language(code: "hi", name: "Hindi"),
    Language(code: "th", name: "Thai"),
    Language(code: "vi", name: "Vietnamese"),
    Language(code: "nl", name: "Dutch"),
    Language(code: "pl", name: "Polish"),
    Language(code: "tr", name: "Turkish"),
    Language(code: "sv", name: "Swedish"),
    Language(code: "da", name: "Danish"),
    Language(code: "no", name: "Norwegian"),
    Language(code: "fi", name: "Finnish"),
    Language(code: "id", name: "Indonesian"),
    Language(code: "ms", name: "Malay"),
    Language(code: "uk", name: "Ukrainian"),
    Language(code: "cs", name: "Czech"),
    Language(code: "el", name: "Greek"),
    Language(code: "he", name: "Hebrew"),
    Language(code: "ro", name: "Romanian"),
    Language(code: "hu", name: "Hungarian"),
]

/// Shared application state
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Persisted Settings
    @AppStorage("geminiAPIKey") var geminiAPIKey: String = ""
    @AppStorage("targetLanguageCode") var targetLanguageCode: String = "zh-Hans"
    @AppStorage("showOverlay") var showOverlay: Bool = true
    @AppStorage("writeToFile") var writeToFile: Bool = true
    @AppStorage("subtitleFontSize") var subtitleFontSize: Double = 22.0
    @AppStorage("originalAudioVolume") var originalAudioVolume: Double = 0.15
    @AppStorage("subtitleFilePathString") var subtitleFilePathString: String = {
        if let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return downloadsURL.path
        }
        return NSHomeDirectory() + "/Downloads"
    }()

    // MARK: - IINA Sync Settings
    @AppStorage("enableIINASync") var enableIINASync: Bool = false
    @AppStorage("iinaSyncPort") var iinaSyncPort: Int = 18930

    // MARK: - Runtime State
    @Published var isTranslating: Bool = false
    @Published var lastInputText: String = ""
    @Published var lastOutputText: String = ""
    @Published var detectedLanguage: String = ""
    @Published var errorMessage: String?
    @Published var statusMessage: String = "Ready"

    // MARK: - IINA Sync Runtime State
    @Published var currentLatency: Double = 0.0
    @Published var iinaSyncServerRunning: Bool = false

    // MARK: - Subtitle File
    var subtitleFilePath: URL {
        URL(fileURLWithPath: subtitleFilePathString)
    }

    var subtitleFileURL: URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "subtitles_\(timestamp).txt"
        return subtitleFilePath.appendingPathComponent(fileName)
    }

    func validateSubtitlePath() -> (isValid: Bool, errorMessage: String?) {
        let fm = FileManager.default
        let path = subtitleFilePath.path

        // Check if path exists
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: path, isDirectory: &isDir) {
            // Try to create the directory
            do {
                try fm.createDirectory(at: subtitleFilePath, withIntermediateDirectories: true, attributes: nil)
                return (true, nil)
            } catch {
                return (false, "Cannot create directory: \(error.localizedDescription)")
            }
        }

        // Check if it's a directory
        if !isDir.boolValue {
            return (false, "Path is not a directory")
        }

        // Check write permissions
        if !fm.isWritableFile(atPath: path) {
            return (false, "No write permission for this directory")
        }

        return (true, nil)
    }

    func resetSubtitles() {
        lastInputText = ""
        lastOutputText = ""
        detectedLanguage = ""
    }
}

/// Notification names
extension Notification.Name {
    static let translationStarted = Notification.Name("translationStarted")
    static let translationStopped = Notification.Name("translationStopped")
    static let subtitleUpdated = Notification.Name("subtitleUpdated")
}
