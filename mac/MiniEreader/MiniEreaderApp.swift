import SwiftUI

@main
struct MiniEreaderApp: App {
    @StateObject private var state: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        AppState.shared = state
        // Accessory policy: no Dock icon, no app menu — stay a pure menu bar app
        // even while a Settings window is open. LSUIElement alone doesn't cover this.
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in state.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
        } label: {
            Image(systemName: "book.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
