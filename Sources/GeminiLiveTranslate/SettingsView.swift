import SwiftUI
import AppKit

/// Main settings view for the Live Translate app
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var translationEngine: TranslationEngine?
    @State private var showingAPIKeyHelp = false
    @State private var isToggling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Gemini Live Translate")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            Divider().padding(.vertical, 12)

            // API Key
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("API Key")
                        .font(.headline)
                    Spacer()
                    Button(action: { showingAPIKeyHelp.toggle() }) {
                        Image(systemName: "questionmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingAPIKeyHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Get your API Key")
                                .font(.headline)
                            Text("1. Go to Google AI Studio\n2. Click \"Create API Key\"\n3. Copy and paste the key here")
                                .fixedSize(horizontal: false, vertical: true)
                            Text("The key is stored locally in UserDefaults.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(width: 280)
                    }
                }

                SecureField("Enter your Gemini API key", text: $appState.geminiAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .padding(.vertical, 8)

            // Target Language
            VStack(alignment: .leading, spacing: 4) {
                Text("Target Language")
                    .font(.headline)
                Picker("", selection: $appState.targetLanguageCode) {
                    ForEach(supportedLanguages) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .labelsHidden()
                .onChange(of: appState.targetLanguageCode) { _, _ in
                    restartTranslationIfNeeded()
                }
            }
            .padding(.vertical, 8)

            Divider().padding(.vertical, 4)

            // Options
            VStack(alignment: .leading, spacing: 12) {
                Text("Options")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show subtitle overlay on screen", isOn: $appState.showOverlay)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Write subtitles to file", isOn: $appState.writeToFile)
                        .fixedSize(horizontal: false, vertical: true)

                    if appState.writeToFile {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Save location")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(appState.subtitleFilePath.path)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.blue)
                                }
                                Spacer()
                                Button(action: browseForPath) {
                                    Text("Browse…")
                                        .font(.caption)
                                }
                            }
                            .padding(6)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(4)
                        }
                    }
                }

                Divider()

                // Subtitle font size — full row
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Subtitle font size")
                        Spacer()
                        Text("\(Int(appState.subtitleFontSize))pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appState.subtitleFontSize, in: 14...36, step: 1)
                }

                // Captured audio playback volume — full row
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Captured audio playback volume")
                        Spacer()
                        Text("\(Int(appState.originalAudioVolume * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appState.originalAudioVolume, in: 0...1, step: 0.05)
                }

                Text("Source language is auto-detected by Gemini. If detection fails, try increasing your player volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)

            Divider().padding(.vertical, 4)

            // IINA Video Sync
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("IINA Video Sync")
                        .font(.headline)
                    Spacer()
                    if appState.iinaSyncServerRunning {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Listening")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Delay IINA video to match translated audio", isOn: $appState.enableIINASync)
                    .fixedSize(horizontal: false, vertical: true)

                if appState.enableIINASync {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", value: $appState.iinaSyncPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .monospacedDigit()
                            .disabled(appState.isTranslating)
                    }

                    if appState.isTranslating {
                        HStack {
                            Text("Current latency:")
                            Spacer()
                            Text("\(String(format: "%.1f", appState.currentLatency))s")
                                .monospacedDigit()
                                .foregroundStyle(.cyan)
                        }
                        .font(.caption)
                    }

                    Text("Install the GeminiLiveSync plugin in IINA, then start translation here. The plugin will automatically delay the video to sync with translated audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)

            Divider().padding(.vertical, 4)

            // Status & Controls
            VStack(spacing: 8) {
                HStack {
                    Circle()
                        .fill(appState.isTranslating ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(appState.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()

                    if !appState.detectedLanguage.isEmpty {
                        Text("Detected: \(appState.detectedLanguage)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Subtitle preview
                if appState.isTranslating {
                    VStack(alignment: .leading, spacing: 4) {
                        if !appState.lastInputText.isEmpty {
                            HStack(alignment: .top) {
                                Text("Original:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: true, vertical: false)
                                Text(appState.lastInputText)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !appState.lastOutputText.isEmpty {
                            HStack(alignment: .top) {
                                Text("Translated:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: true, vertical: false)
                                Text(appState.lastOutputText)
                                    .font(.caption)
                                    .foregroundColor(.cyan)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(6)
                }

                // Error message
                if let error = appState.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Start/Stop button
                Button(action: toggleTranslation) {
                    HStack {
                        if isToggling {
                            ProgressView()
                                .controlSize(.small)
                            Text(appState.isTranslating ? "Stopping…" : "Starting…")
                        } else {
                            Image(systemName: appState.isTranslating ? "stop.circle.fill" : "play.circle.fill")
                            Text(appState.isTranslating ? "Stop Translation" : "Start Translation")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(isToggling ? .gray : (appState.isTranslating ? .red : .blue))
                .disabled(appState.geminiAPIKey.isEmpty || isToggling)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.vertical, 8)
        }
        .padding(20)
        .frame(width: 420)
    }

    private func restartTranslationIfNeeded() {
        guard appState.isTranslating, !isToggling else { return }

        Task {
            isToggling = true
            await translationEngine?.stop()
            translationEngine = nil

            let engine = TranslationEngine(
                apiKey: appState.geminiAPIKey,
                targetLanguageCode: appState.targetLanguageCode,
                showOverlay: appState.showOverlay,
                writeToFile: appState.writeToFile,
                subtitleFontSize: appState.subtitleFontSize
            )
            translationEngine = engine

            do {
                try await engine.start()
            } catch {
                appState.errorMessage = error.localizedDescription
                appState.statusMessage = "Error"
            }
            isToggling = false
        }
    }

    private func toggleTranslation() {
        guard !isToggling else { return }
        isToggling = true

        if appState.isTranslating {
            Task {
                await translationEngine?.stop()
                translationEngine = nil
                isToggling = false
            }
        } else {
            Task {
                let engine = TranslationEngine(
                    apiKey: appState.geminiAPIKey,
                    targetLanguageCode: appState.targetLanguageCode,
                    showOverlay: appState.showOverlay,
                    writeToFile: appState.writeToFile,
                    subtitleFontSize: appState.subtitleFontSize
                )
                translationEngine = engine

                do {
                    try await engine.start()
                } catch {
                    appState.errorMessage = error.localizedDescription
                    appState.statusMessage = "Error"
                }
                isToggling = false
            }
        }
    }

    private func browseForPath() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = appState.subtitleFilePath

        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                appState.subtitleFilePathString = url.path

                let (isValid, errorMessage) = appState.validateSubtitlePath()
                if !isValid {
                    appState.errorMessage = errorMessage
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
}
