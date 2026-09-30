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
    // 2026-08-12: published `isExpensive` from NWPath so
    // SmartLibraryManager can skip auto-download on metered
    // WiFi (hotspots, Low Data Mode). iOS sets isExpensive when
    // the OS thinks the user wouldn't want background data on
    // this connection. Updated on every path change.
    @Published private(set) var isMetered: Bool = false

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
    // 2026-09-14 (Mavis race-condition fix): the 5s /health
    // timeout was still racing Tailscale wakeup handshakes
    // (the OS reports `path.status == .satisfied` as soon as
    // the utun interface is up, but the tunnel routing isn't
    // ready until the key exchange completes — typically
    // 5–10s on cold launch, occasionally 15–20s). The banner
    // would show even when the Mac + backend were fine. Fix:
    //   1. Bump /health timeout to 30s to match APIService's
    //      data-path timeout (both hit the same host — the
    //      health probe was 6× more aggressive than the call
    //      that actually mattered).
    //   2. Lengthen the silent retry from 1.5s → 5s so we
    //      give Tailscale more room to finish its handshake.
    //   3. Require 3 consecutive failures (was 2) before
    //      flipping the banner. A single healthy probe resets
    //      the counter, so this only affects the wakeup
    //      window — sustained outages still get caught in
    //      ~10–15s, well within the 60s periodic cadence.
    private var consecutiveBackendFailures: Int = 0
    private let backendRetryDelayNanos: UInt64 = 5_000_000_000  // 5s
    /// True while a retry is in flight, so the periodic
    /// timer doesn't cancel the retry and reset the user's
    /// grace window.
    private var retryInFlight: Bool = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.connectionType = path.availableInterfaces.first?.type
                self?.isMetered = path.isExpensive
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
        guard !YTAudioPlayerApp.isRunningTests else { return }
        let identity = BackendConfiguration.shared.identity
        let baseURL = identity.origin.absoluteString
        guard let url = URL(string: "\(baseURL)/health") else {
            await MainActor.run {
                self.recordFailure()
                self.lastBackendCheck = Date()
            }
            return
        }

        var request = URLRequest(url: url)
        // 30s timeout. Matches APIService's
        // timeoutIntervalForRequest so the health probe and
        // the actual data request have the same transport
        // ceiling — they hit the same host, so the only
        // reason one would fail while the other succeeds is
        // a request-side timeout mismatch. The backend's
        // /health is a tiny ~100-byte JSON response; on a
        // healthy LAN it returns in <50ms. 30s is the
        // ceiling for "Tailscale is still finishing its
        // key exchange on wakeup" — empirically 5–20s on
        // cold launch, occasionally longer.
        request.timeoutInterval = 30.0
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
            guard BackendConfiguration.shared.isCurrent(identity) else { return }
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
        if consecutiveBackendFailures >= 3 {
            // Genuine outage — the banner is fair signal.
            // 3 consecutive failures means the retry (at
            // 5s after the 1st failure, so ~5s + 30s + 5s +
            // 30s = ~70s window for the 3rd failure to
            // land) has also failed, which is well past any
            // reasonable Tailscale wakeup time.
            retryInFlight = false
            isBackendReachable = false
        } else {
            // 1st or 2nd failure: silent retry. Banner
            // stays hidden — Tailscale key exchange on
            // wakeup can easily eat 5–20s, and we don't
            // want a transient handshake blip to look
            // like a real outage.
            isBackendReachable = true
            if !retryInFlight {
                retryInFlight = true
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: self?.backendRetryDelayNanos ?? 5_000_000_000)
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
