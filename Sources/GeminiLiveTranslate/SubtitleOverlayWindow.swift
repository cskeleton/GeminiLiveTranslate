import AppKit
import SwiftUI

/// A floating overlay window that displays original and translated subtitles
@MainActor
class SubtitleOverlayWindow: NSWindowController {
    private var originalLabel: NSTextField!
    private var translatedLabel: NSTextField!
    private var originalLangLabel: NSTextField!
    private var translatedLangLabel: NSTextField!
    private var containerView: NSVisualEffectView!

    private var inputBuffer: String = ""
    private var outputBuffer: String = ""
    private var hideTimer: Timer?

    init() {
        // Create a borderless, transparent, floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        configureWindow(panel)
        setupUI()
        positionWindow()

        // Listen for subtitle updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSubtitleUpdate(_:)),
            name: .subtitleUpdated,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated private func configureWindow(_ panel: NSPanel) {
        MainActor.assumeIsolated {
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.worksWhenModal = true
        }
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Visual effect view for blur background
        containerView = NSVisualEffectView(frame: contentView.bounds)
        containerView.autoresizingMask = [.width, .height]
        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 12
        containerView.layer?.masksToBounds = true
        containerView.alphaValue = 0.92
        contentView.addSubview(containerView)

        // Stack view for labels
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stackView)

        // Original text row
        let originalRow = NSStackView()
        originalRow.orientation = .horizontal
        originalRow.alignment = .firstBaseline
        originalRow.spacing = 8

        originalLangLabel = createLangLabel(text: "Original")
        originalLabel = createTextLabel(color: .white, fontSize: AppState.shared.subtitleFontSize)

        originalRow.addArrangedSubview(originalLangLabel)
        originalRow.addArrangedSubview(originalLabel)

        // Translated text row
        let translatedRow = NSStackView()
        translatedRow.orientation = .horizontal
        translatedRow.alignment = .firstBaseline
        translatedRow.spacing = 8

        translatedLangLabel = createLangLabel(text: "Translation")
        translatedLabel = createTextLabel(color: NSColor.systemYellow, fontSize: AppState.shared.subtitleFontSize + 2)

        translatedRow.addArrangedSubview(translatedLangLabel)
        translatedRow.addArrangedSubview(translatedLabel)

        stackView.addArrangedSubview(originalRow)
        stackView.addArrangedSubview(translatedRow)

        // Layout constraints
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -16),
            stackView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

            originalLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            translatedLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
        ])

        // Make labels wrap text
        originalLabel.maximumNumberOfLines = 0
        translatedLabel.maximumNumberOfLines = 0
        originalLabel.preferredMaxLayoutWidth = 700
        translatedLabel.preferredMaxLayoutWidth = 700
    }

    private func createLangLabel(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 72)
        ])
        return label
    }

    private func createTextLabel(color: NSColor, fontSize: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: fontSize, weight: .regular)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        guard let windowFrame = window?.frame else { return }

        let x = screenFrame.midX - windowFrame.width / 2
        let y = screenFrame.minY + 80  // 80pt from bottom

        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Subtitle Updates

    @objc func handleSubtitleUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        if let inputText = userInfo["inputText"] as? String {
            inputBuffer = inputText
            originalLabel?.stringValue = inputText
        }

        if let outputText = userInfo["outputText"] as? String {
            outputBuffer = outputText
            translatedLabel?.stringValue = outputText
        }

        if let inputLang = userInfo["inputLang"] as? String, !inputLang.isEmpty {
            originalLangLabel?.stringValue = inputLang
        }

        if let outputLang = userInfo["outputLang"] as? String, !outputLang.isEmpty {
            translatedLangLabel?.stringValue = outputLang
        }

        // Show window and auto-hide after delay
        showWindowAnimated()
        resetHideTimer()
    }

    private func showWindowAnimated() {
        guard let window = window else { return }
        if !window.isVisible {
            window.alphaValue = 0
            showWindow(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1
            }
        }
    }

    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideWindowAnimated()
            }
        }
    }

    private func hideWindowAnimated() {
        guard let window = window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.close()
            }
        })
    }

    nonisolated deinit {
        // Timer cleanup happens automatically when the object is deallocated
    }
}
