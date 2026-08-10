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

    // v1.6.8 (CV-10.5): the user reported the
    // "Can't reach music library — is your Mac awake?" banner
    // flashing on every cold launch for a few seconds, then
    // disappearing. Root cause: the first /health probe fires
    // from `init()` BEFORE the Wi-Fi/Tailscale path has fully
    // negotiated, so the request hits the 5s timeout, the
    // banner shows, and then the next probe (triggered by the
    // OS path coming up) succeeds and clears the banner. The
    // banner is technically correct, but the user reads it as
    // a false positive because the backend is actually fine.
    //
    // The fix: don't show the banner on the FIRST failed
    // probe. Schedule a quick retry 1.5s later. Only flip
    // `isBackendReachable` to false after the SECOND
    // consecutive failure. A successful probe resets the
    // counter, so a healthy backend never triggers the
    // banner at all.
    private var consecutiveBackendFailures: Int = 0
    private let backendRetryDelayNanos: UInt64 = 1_500_000_000  // 1.5s
    /// True while a retry is in flight, so the periodic
    /// timer doesn't cancel the retry and reset the user's
    /// grace window.
    private var retryInFlight: Bool = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.connectionType = path.availableInterfaces.first?.type
                if path.status == .satisfied {
                    // v1.6.8 (CV-10.5): when the OS path comes
                    // back up, optimistically assume the
                    // backend is reachable. The probe that
                    // runs immediately below will either
                    // confirm (counter resets, stays at true)
                    // or trigger a silent retry (counter=1,
                    // banner hidden). This prevents the
                    // "Can't reach" banner from flashing for
                    // ~5s while the first post-reconnect
                    // probe is in flight.
                    self?.isBackendReachable = true
                    self?.consecutiveBackendFailures = 0
                    self?.retryInFlight = false
                    // OS path came up. Probe the backend so the
                    // "Wi-Fi fine, backend down" state can resolve
                    // back to "all good" without waiting for the
                    // 60s timer.
                    self?.checkBackendHealth()
                } else {
                    // OS path went down. No point probing.
                    self?.isBackendReachable = false
                    // v1.6.8 (CV-10.5): also reset the
                    // counter so when the path comes back the
                    // first probe doesn't get penalized for a
                    // previous-session failure.
                    self?.consecutiveBackendFailures = 0
                    self?.retryInFlight = false
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
            await MainActor.run {
                self.recordFailure()
                self.lastBackendCheck = Date()
            }
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
            self.lastBackendCheck = Date()
            if reachable {
                self.recordSuccess()
            } else {
                self.recordFailure()
            }
        }
    }

    /// v1.6.8 (CV-10.5): probe succeeded. Reset the
    /// failure counter and make sure isBackendReachable
    /// is true. The counter reset is the important part —
    /// it means a single successful probe anywhere (cold
    /// launch, scene phase .active, periodic timer) clears
    /// the slate and the next failure will again get a
    /// silent retry.
    private func recordSuccess() {
        consecutiveBackendFailures = 0
        retryInFlight = false
        isBackendReachable = true
    }

    /// v1.6.8 (CV-10.5): probe failed. Bump the counter;
    /// only flip isBackendReachable to false after the
    /// second consecutive failure. On the first failure
    /// (and on any failure that follows a successful
    /// probe) schedule a silent retry 1.5s later so the
    /// banner doesn't flash on cold launch when the
    /// backend is just slow to wake up.
    private func recordFailure() {
        consecutiveBackendFailures += 1
        if consecutiveBackendFailures >= 2 {
            // Genuine outage — the banner is fair signal.
            retryInFlight = false
            isBackendReachable = false
        } else {
            // First failure: silent retry.
            isBackendReachable = true
            if !retryInFlight {
                retryInFlight = true
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: self?.backendRetryDelayNanos ?? 1_500_000_000)
                    await self?.retryProbe()
                }
            }
        }
    }

    /// v1.6.8 (CV-10.5): the silent retry. Runs the
    /// probe again; recordSuccess / recordFailure will
    /// reset retryInFlight via the success path or
    /// escalate the counter on the failure path. We
    /// don't cancel the in-flight healthCheckTask here
    /// (it has already completed since we're in its
    /// result handler) so we just start a new one.
    private func retryProbe() async {
        await runHealthCheck()
    }
}
