import SwiftUI
import AppKit
import ScreenCaptureKit

@main
struct GeminiLiveTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppState.shared)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    var subtitleWindow: SubtitleOverlayWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Menu bar only

        setupStatusBar()
        checkScreenRecordingPermission()

        // Show settings on first launch if no API key
        if AppState.shared.geminiAPIKey.isEmpty {
            showSettings()
        }

        // Observe translation state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationDidStart),
            name: .translationStarted,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationDidStop),
            name: .translationStopped,
            object: nil
        )
    }

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Live Translate")
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc func togglePopover() {
        // Right-click → show quit menu
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuitMenu()
            return
        }

        // Left-click → toggle settings
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showSettings()
        }
    }

    func showQuitMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Gemini Live Translate", action: #selector(NSApp.terminate), keyEquivalent: "q"))
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc func showSettings() {
        let settingsView = SettingsView()
            .environmentObject(AppState.shared)
        let hostingView = NSHostingView(rootView: settingsView)
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = hostingView
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func checkScreenRecordingPermission() {
        Task.detached {
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            if content == nil {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Screen Recording Permission Required"
                    alert.informativeText = "Gemini Live Translate needs Screen Recording permission to capture system audio.\n\nPlease grant permission in System Settings → Privacy & Security → Screen Recording."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
        }
    }

    @objc func translationDidStart() {
        subtitleWindow = SubtitleOverlayWindow()
        subtitleWindow?.showWindow(nil)
    }

    @objc func translationDidStop() {
        subtitleWindow?.close()
        subtitleWindow = nil
    }
}
