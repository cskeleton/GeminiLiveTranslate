import SwiftUI

/// Main settings view for the Live Translate app
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var translationEngine: TranslationEngine?
    @State private var showingAPIKeyHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            .padding(.bottom, 4)

            Divider()

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
                            Text("1. Go to [Google AI Studio](https://aistudio.google.com/apikey)")
                            Text("2. Click \"Create API Key\"")
                            Text("3. Copy and paste the key here")
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
            }

            Divider()

            // Options
            VStack(alignment: .leading, spacing: 8) {
                Text("Options")
                    .font(.headline)

                Toggle("Show subtitle overlay on screen", isOn: $appState.showOverlay)
                Toggle("Write subtitles to file (~/Downloads)", isOn: $appState.writeToFile)

                HStack {
                    Text("Subtitle font size")
                    Slider(value: $appState.subtitleFontSize, in: 14...36, step: 1)
                    Text("\(Int(appState.subtitleFontSize))pt")
                        .monospacedDigit()
                        .frame(width: 36)
                }

                HStack {
                    Text("Captured audio playback volume")
                    Slider(value: $appState.originalAudioVolume, in: 0...1, step: 0.05)
                    Text("\(Int(appState.originalAudioVolume * 100))%")
                        .monospacedDigit()
                        .frame(width: 36)
                }
                Text("Source language is auto-detected by Gemini. If detection fails, try increasing your player volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

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
                                    .frame(width: 68, alignment: .trailing)
                                Text(appState.lastInputText)
                                    .font(.caption)
                                    .lineLimit(2)
                            }
                        }
                        if !appState.lastOutputText.isEmpty {
                            HStack(alignment: .top) {
                                Text("Translated:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 68, alignment: .trailing)
                                Text(appState.lastOutputText)
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                                    .lineLimit(2)
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
                        .lineLimit(2)
                }

                // Start/Stop button
                Button(action: toggleTranslation) {
                    HStack {
                        Image(systemName: appState.isTranslating ? "stop.circle.fill" : "play.circle.fill")
                        Text(appState.isTranslating ? "Stop Translation" : "Start Translation")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.isTranslating ? .red : .blue)
                .disabled(appState.geminiAPIKey.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onDisappear {
            // Don't stop translation when settings close
        }
    }

    private func toggleTranslation() {
        if appState.isTranslating {
            Task {
                await translationEngine?.stop()
                translationEngine = nil
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
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
}
