import AppKit
import SwiftUI

/// A floating overlay window that displays original and translated subtitles
@MainActor
class SubtitleOverlayWindow: NSWindowController {
    private var originalLabel: PaddedLabel!
    private var translatedLabel: PaddedLabel!
    private var stackView: NSStackView!

    private var hideTimer: Timer?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        configureWindow(panel)
        setupUI()
        positionWindow()

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

    private func configureWindow(_ panel: NSPanel) {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.ignoresMouseEvents = false
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 3
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        let fontSize = AppState.shared.subtitleFontSize

        // Original text — white with dark background pill
        originalLabel = PaddedLabel()
        originalLabel.font = .systemFont(ofSize: fontSize, weight: .regular)
        originalLabel.textColor = NSColor(white: 1.0, alpha: 0.95)
        originalLabel.backgroundColor = NSColor(white: 0.0, alpha: 0.65)
        originalLabel.cornerRadius = 6
        originalLabel.horizontalPadding = 10
        originalLabel.verticalPadding = 4
        originalLabel.alignment = .center
        originalLabel.maximumNumberOfLines = 2
        originalLabel.lineBreakMode = .byWordWrapping
        originalLabel.translatesAutoresizingMaskIntoConstraints = false
        originalLabel.isHidden = true

        // Translated text — bright cyan with dark background pill
        translatedLabel = PaddedLabel()
        translatedLabel.font = .systemFont(ofSize: fontSize + 2, weight: .semibold)
        translatedLabel.textColor = NSColor(red: 0.3, green: 1.0, blue: 0.95, alpha: 1.0) // bright cyan
        translatedLabel.backgroundColor = NSColor(white: 0.0, alpha: 0.75)
        translatedLabel.cornerRadius = 6
        translatedLabel.horizontalPadding = 10
        translatedLabel.verticalPadding = 4
        translatedLabel.alignment = .center
        translatedLabel.maximumNumberOfLines = 3
        translatedLabel.lineBreakMode = .byWordWrapping
        translatedLabel.translatesAutoresizingMaskIntoConstraints = false
        translatedLabel.isHidden = true

        stackView.addArrangedSubview(originalLabel)
        stackView.addArrangedSubview(translatedLabel)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stackView.widthAnchor.constraint(lessThanOrEqualToConstant: 900),

            originalLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 880),
            translatedLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 880),
        ])
    }

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        guard let windowFrame = window?.frame else { return }

        let x = screenFrame.midX - windowFrame.width / 2
        let y = screenFrame.minY + 60

        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Subtitle Updates

    @objc func handleSubtitleUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        if let inputText = userInfo["inputText"] as? String, !inputText.isEmpty {
            originalLabel.stringValue = inputText
            originalLabel.isHidden = false
        }

        if let outputText = userInfo["outputText"] as? String, !outputText.isEmpty {
            translatedLabel.stringValue = outputText
            translatedLabel.isHidden = false
        }

        showWindowAnimated()
        fitToContent()
        resetHideTimer()
    }

    private func fitToContent() {
        guard window?.contentView != nil else { return }
        stackView.layoutSubtreeIfNeeded()

        let contentSize = stackView.fittingSize
        let padding: CGFloat = 16
        let newWidth = contentSize.width + padding * 2
        let newHeight = contentSize.height + padding

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let clampedWidth = min(newWidth, screenFrame.width - 40)
        let x = screenFrame.midX - clampedWidth / 2
        let y = screenFrame.minY + 60

        window?.setFrame(NSRect(x: x, y: y, width: clampedWidth, height: newHeight), display: true, animate: window?.isVisible ?? false)
    }

    private func showWindowAnimated() {
        guard let window = window else { return }
        if !window.isVisible {
            window.alphaValue = 0
            showWindow(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 1
            }
        }
    }

    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideWindowAnimated()
            }
        }
    }

    private func hideWindowAnimated() {
        guard let window = window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.close()
            }
        })
    }
}

// MARK: - PaddedLabel: rounded-rect background label

/// A label that draws a rounded-rect background and supports padding
class PaddedLabel: NSTextField {
    var cornerRadius: CGFloat = 6 {
        didSet { needsDisplay = true }
    }
    var horizontalPadding: CGFloat = 10 {
        didSet { needsDisplay = true }
    }
    var verticalPadding: CGFloat = 4 {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        isBezeled = false
        drawsBackground = true
        isEditable = false
        isSelectable = false
        cell?.wraps = true
        stringValue = ""
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let superSize = super.intrinsicContentSize
        return NSSize(
            width: superSize.width + horizontalPadding * 2,
            height: superSize.height + verticalPadding * 2
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw rounded rect background
        let bgRect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
        backgroundColor?.setFill()
        path.fill()

        // Draw text with padding
        let textRect = bounds.insetBy(
            dx: horizontalPadding,
            dy: verticalPadding
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = lineBreakMode

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 14),
            .foregroundColor: textColor ?? .white,
            .paragraphStyle: paragraphStyle
        ]
        (stringValue as NSString).draw(in: textRect, withAttributes: attrs)
    }
}
