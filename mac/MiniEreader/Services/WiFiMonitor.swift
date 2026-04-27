import Foundation
import CoreWLAN
import CoreLocation
import Combine

/// Polls the current Wi-Fi SSID, scans for the reader's AP in range, and
/// drives connect/disconnect to the reader. macOS 14+ requires Location
/// permission to read the SSID; the same permission covers scanning.
@MainActor
final class WiFiMonitor: NSObject, ObservableObject {
    static let expectedSSID = "CrossPoint-Reader"

    @Published var currentSSID: String?
    @Published var isConnectedToReader: Bool = false
    @Published var isReaderInRange: Bool = false
    @Published var locationAuthorized: Bool = false

    /// The SSID we were on before we switched to the reader, so we can rejoin
    /// it after the sync. Only captured when we initiated the switch ourselves.
    private(set) var previousSSID: String?

    private let locationManager = CLLocationManager()
    private var ssidTimer: Timer?
    private var scanTask: Task<Void, Never>?
    /// Scan every 2s while the popover is visible, every 20s in the background.
    /// Fast scans are expensive and slightly disturb other Wi-Fi traffic, so
    /// we only do them when the user is actively looking.
    private var fastScanning: Bool = false

    override init() {
        super.init()
        locationManager.delegate = self
        updateAuthorization()
    }

    func start() {
        requestLocationIfNeeded()
        refreshSSID()
        ssidTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSSID() }
        }
        startScanLoop()
    }

    func stop() {
        ssidTimer?.invalidate()
        ssidTimer = nil
        scanTask?.cancel()
        scanTask = nil
    }

    func requestLocationIfNeeded() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    private func updateAuthorization() {
        let status = locationManager.authorizationStatus
        locationAuthorized = (status == .authorizedAlways || status == .authorized)
    }

    private func refreshSSID() {
        let ssid = CWWiFiClient.shared().interface()?.ssid()
        self.currentSSID = ssid
        let isReader = (ssid == Self.expectedSSID)
        self.isConnectedToReader = isReader
        // Once we're on the reader, we know it's in range by definition.
        if isReader { self.isReaderInRange = true }
    }

    /// Scans for the reader SSID in range. 20s interval by default; 2s when
    /// `fastScanning` is true (popover open).
    private func startScanLoop() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanOnce()
                let ns = (self?.fastScanning == true) ? 2 : 20
                try? await Task.sleep(nanoseconds: UInt64(ns) * 1_000_000_000)
            }
        }
    }

    /// Called by the popover as it shows/hides. Kicks an immediate scan when
    /// turning on so the pill updates before the next tick.
    func setFastScanning(_ enabled: Bool) {
        fastScanning = enabled
        if enabled {
            refreshSSID()
            Task { await scanOnce() }
        }
    }

    func scanOnce() async {
        if isConnectedToReader { return }
        guard let iface = CWWiFiClient.shared().interface() else {
            NSLog("[wifi] no interface")
            return
        }

        // Try name-filtered scan first — it's cheaper. Fall back to a broad
        // scan if it returns empty, because some access points hide their
        // SSID from name-filtered probes.
        var hits: Set<CWNetwork> = []
        do {
            hits = try iface.scanForNetworks(withName: Self.expectedSSID)
        } catch {
            NSLog("[wifi] name scan failed: \(error.localizedDescription)")
        }

        if hits.isEmpty {
            do {
                let all = try iface.scanForNetworks(withSSID: nil)
                let names = all.compactMap { $0.ssid }.joined(separator: ", ")
                NSLog("[wifi] broad scan saw %d SSIDs: %@", all.count, names)
                hits = all.filter { $0.ssid == Self.expectedSSID }
            } catch {
                NSLog("[wifi] broad scan failed: \(error.localizedDescription)")
            }
        }

        isReaderInRange = !hits.isEmpty
    }

    // MARK: - Connect / disconnect

    enum WiFiError: Error, LocalizedError {
        case noInterface
        case readerNotFound
        case associateFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noInterface: return "No Wi-Fi interface available."
            case .readerNotFound: return "E-Paper hotspot not in range."
            case .associateFailed(let m): return "Connect failed: \(m)"
            case .timedOut: return "Connect timed out."
            }
        }
    }

    /// Associate with the reader's AP. Remembers the current SSID so we can
    /// rejoin it later. Assumes the reader's AP is open (no password), which
    /// matches the CrossPoint firmware's File Transfer mode.
    func connectToReader() async throws {
        guard let iface = CWWiFiClient.shared().interface() else { throw WiFiError.noInterface }

        if iface.ssid() != Self.expectedSSID {
            previousSSID = iface.ssid()
        }

        // Prefer a broad scan here: name-filtered scans sometimes return nil
        // for APs that CoreWLAN doesn't cache. We already know the hotspot is
        // up (the pill is yellow), so a broad scan is the safer bet.
        let all = (try? iface.scanForNetworks(withSSID: nil)) ?? []
        guard let target = all.first(where: { $0.ssid == Self.expectedSSID }) else {
            throw WiFiError.readerNotFound
        }

        // Drop whatever we're on so the association has a clean interface.
        iface.disassociate()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // tmpErr (-3900) is CoreWLAN's "temporary failure", often fired when
        // the Wi-Fi agent is still mid-transition. Retry with backoff.
        var lastError: NSError?
        for attempt in 0..<3 {
            do {
                try iface.associate(to: target, password: nil)
                lastError = nil
                break
            } catch let e as NSError {
                NSLog("[wifi] associate attempt \(attempt+1) failed: code=\(e.code) \(e.localizedDescription)")
                lastError = e
                try? await Task.sleep(nanoseconds: UInt64(1 + attempt) * 1_000_000_000)
            }
        }
        if let e = lastError {
            throw WiFiError.associateFailed(
                "\(e.localizedDescription) — try clicking \(Self.expectedSSID) in the Wi-Fi menu manually.")
        }

        try await waitForSSID(Self.expectedSSID, timeoutSeconds: 20)
        refreshSSID()
    }

    /// Rejoin the network we were on before connectToReader(). macOS looks up
    /// stored credentials in the system Wi-Fi keychain, so no password needed
    /// for previously-known networks.
    func reconnectToPrevious() async throws {
        guard let previous = previousSSID else { return }
        guard let iface = CWWiFiClient.shared().interface() else { throw WiFiError.noInterface }

        let networks = (try? iface.scanForNetworks(withName: previous)) ?? []
        guard let target = networks.first else { throw WiFiError.readerNotFound }

        do {
            try iface.associate(to: target, password: nil)
        } catch {
            throw WiFiError.associateFailed(error.localizedDescription)
        }
        try await waitForSSID(previous, timeoutSeconds: 15)
        refreshSSID()
    }

    private func waitForSSID(_ target: String, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if CWWiFiClient.shared().interface()?.ssid() == target { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw WiFiError.timedOut
    }
}

extension WiFiMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.updateAuthorization()
            self.refreshSSID()
        }
    }
}
