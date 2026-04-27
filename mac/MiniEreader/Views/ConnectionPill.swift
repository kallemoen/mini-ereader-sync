import SwiftUI

struct ConnectionPill: View {
    @ObservedObject var wifi: WiFiMonitor

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    private var dotColor: Color {
        if wifi.isConnectedToReader { return .green }
        if wifi.isReaderInRange { return .yellow }
        return .gray.opacity(0.5)
    }

    private var label: String {
        if !wifi.locationAuthorized { return "Location permission needed" }
        if wifi.isConnectedToReader { return "Connected to \(WiFiMonitor.expectedSSID)" }
        if wifi.isReaderInRange { return "\(WiFiMonitor.expectedSSID) in range" }
        return "Not connected"
    }
}
