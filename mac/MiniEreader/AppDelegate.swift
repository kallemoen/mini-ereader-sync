import AppKit
import ServiceManagement
import SwiftUI

/// Owns app-lifecycle concerns that SwiftUI scenes can't express:
///   - Register for auto-launch at login.
///   - Respond to "reopen" events (clicking the app icon while already
///     running) — without this a click is silent, because we have no Dock
///     icon and no persistently-visible window.
///   - Host the Settings window as a proper NSWindow so it can be opened
///     from anywhere, independent of whether the menu bar popover is up.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSLog("[delegate] didFinishLaunching")
        enableLaunchAtLogin()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        NSLog("[delegate] reopen hasVisibleWindows=%d", hasVisibleWindows ? 1 : 0)
        if !hasVisibleWindows {
            showSettings()
        }
        return true
    }

    // MARK: - Settings window

    @MainActor
    func showSettings() {
        // An `.accessory` app can't bring its own windows to the front — the
        // activation policy itself blocks `activate(ignoringOtherApps:)`.
        // Temporarily promote to `.regular`, show the window, and drop back
        // to `.accessory` when the user closes it.
        NSApp.setActivationPolicy(.regular)

        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(onSave: { [weak self] in
            Task { @MainActor in AppState.shared?.onSettingsSaved() }
            self?.settingsWindow?.performClose(nil)
        })
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Mini E-Reader Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Login item

    private func enableLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do {
            try service.register()
            NSLog("[launch] registered as login item")
        } catch {
            NSLog("[launch] could not register login item: %@",
                  error.localizedDescription)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Drop back to `.accessory` when Settings closes so we stay a pure menu
    /// bar app (no Dock icon, no app menu).
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
