import SwiftUI

struct SyncButton: View {
    @ObservedObject var state: AppState
    /// Observed directly so SwiftUI re-renders when Wi-Fi state changes.
    /// Reading it through `state.wifi` would not, because nested
    /// ObservableObjects don't propagate to parent observers.
    @ObservedObject var wifi: WiFiMonitor

    var body: some View {
        Button(action: action) {
            HStack {
                if state.isSyncing {
                    ProgressView().controlSize(.small)
                }
                Text(label)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isEnabled)
    }

    private func action() {
        Task {
            if wifi.isConnectedToReader {
                await state.syncNow()
            } else {
                await state.connectAndSync()
            }
        }
    }

    private var isEnabled: Bool {
        if state.isSyncing { return false }
        if state.readyCount == 0 { return false }
        return wifi.isConnectedToReader || wifi.isReaderInRange
    }

    private var label: String {
        if state.isSyncing { return "Syncing…" }
        if state.readyCount == 0 { return "Nothing to sync" }
        if wifi.isConnectedToReader {
            return "Sync \(state.readyCount) article\(state.readyCount == 1 ? "" : "s")"
        }
        if wifi.isReaderInRange {
            return "Connect & sync \(state.readyCount)"
        }
        return "\(WiFiMonitor.expectedSSID) hotspot not in range"
    }
}
