import Network
import Combine
import Foundation

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    // S18 / v1.6.7 (CV-10): the user was getting confusing
    // "Failed to load stations" errors with no signal about
    // what's wrong. The previous NetworkMonitor only watched
    // the OS-level path — it could tell "Wi-Fi connected" but
    // not "backend reachable". When the user's Tailscale went
    // down, or their Mac went to sleep, or the backend wasn't
    // running, the app showed the same "loading…" state as a
    // genuine network error. The two states are different
    // problems with different fixes, and the user couldn't tell
    // which one was happening. Now we ping the backend's /health
    // endpoint to distinguish "Wi-Fi fine, backend down" from
    // "fully offline".
    @Published private(set) var isConnected = true
    @Published private(set) var connectionType: NWInterface.InterfaceType?
    @Published private(set) var isBackendReachable = true
    @Published private(set) var lastBackendCheck: Date?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var healthCheckTask: Task<Void, Never>?
    /// 60s interval is a balance between "tell me quickly when
    /// the backend comes back" and "don't burn battery pinging
    /// the Mac on every tick". The full health check is also
    /// triggered on app launch and on scene phase .active, so
    /// this is the steady-state cadence.
    private let healthCheckInterval: TimeInterval = 60
    private var periodicTimer: Timer?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.connectionType = path.availableInterfaces.first?.type
                if path.status == .satisfied {
                    // OS path came up. Probe the backend so the
                    // "Wi-Fi fine, backend down" state can resolve
                    // back to "all good" without waiting for the
                    // 60s timer.
                    self?.checkBackendHealth()
                } else {
                    // OS path went down. No point probing.
                    self?.isBackendReachable = false
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        healthCheckTask?.cancel()
        periodicTimer?.invalidate()
    }

    // MARK: - Backend Health Check

    /// Pings the backend's /health endpoint. Safe to call from
    /// anywhere; cancels any in-flight check and starts a new
    /// one. Updates `isBackendReachable` on the main thread
    /// when the response lands (or the 5s timeout fires).
    ///
    /// Triggers:
    ///   - NetworkMonitor init (app launch)
    ///   - OS path comes back (Wi-Fi reconnects)
    ///   - Scene phase becomes .active (user reopens the app)
    ///   - 60s periodic timer
    ///   - Manual: NetworkMonitor.shared.checkBackendHealth()
    func checkBackendHealth() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            await self?.runHealthCheck()
        }
    }

    /// Starts the 60s periodic timer. Idempotent — calling
    /// twice doesn't double the cadence. The timer fires on
    /// the main run loop so the @Published updates happen on
    /// the main thread automatically.
    func startPeriodicHealthChecks() {
        guard periodicTimer == nil else { return }
        periodicTimer = Timer.scheduledTimer(
            withTimeInterval: healthCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkBackendHealth()
        }
    }

    func stopPeriodicHealthChecks() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    private func runHealthCheck() async {
        let baseURL = await MainActor.run { APIService.shared.baseURL }
        guard let url = URL(string: "\(baseURL)/health") else {
            await MainActor.run { self.isBackendReachable = false }
            return
        }

        var request = URLRequest(url: url)
        // 5s timeout. The backend's /health is a tiny
        // ~100-byte JSON response; on a healthy LAN it
        // returns in <50ms. 5s is a generous ceiling for
        // "Tailscale is up but the Mac is asleep and slow
        // to wake the listener".
        request.timeoutInterval = 5.0
        request.httpMethod = "GET"

        let reachable: Bool
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                reachable = true
            } else {
                reachable = false
            }
        } catch {
            // Timeout, connection refused, DNS failure,
            // Tailscale-down — all map to "not reachable"
            // from the app's perspective.
            reachable = false
        }

        await MainActor.run {
            self.isBackendReachable = reachable
            self.lastBackendCheck = Date()
        }
    }
}
