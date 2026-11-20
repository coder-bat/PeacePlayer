import SwiftUI
#if canImport(UIKit)
import UIKit  // S17-H (round 7): UIPasteboard for tap-to-copy on connection test errors
#endif

struct SettingsView: View {
    @StateObject private var favoriteArtists = FavoriteArtistsManager.shared
    @StateObject private var auth = AuthService.shared
    // 2026-08-12: Smart Library (auto-download on WiFi + auto-
    // cleanup). Observed here so the status row re-renders
    // when the manager updates its last-run timestamps.
    @StateObject private var smartLibrary = SmartLibraryManager.shared
    @State private var showClearCacheConfirmation = false
    @State private var showSignOutConfirmation = false
    // 2026-11-18: the avatar / display-name / sign-out sheet used to
    // be reached from the profile chip on Home. The chip is gone (the
    // deck is a record player, not an account screen), so the sheet
    // now opens from the account row below — tapping the email.
    @State private var showProfileSheet = false
    @State private var showBackendSettings = false
    @State private var showAudioSettings = false  // S13
    @State private var showEqualizer = false  // S15: real 10-band EQ
    // 2026-08-12: v1.8.2 — confirmation modal for the
    // "Refresh downloads" button. The refresh is
    // destructive (deletes ALL downloads, then re-downloads),
    // so we want a clear confirmation before kicking it off.
    @State private var showRefreshConfirm = false
    @State private var isSigningOut = false
    @State private var cacheSize: String = "Calculating..."

    // Deck design system (docs/design/deck-design-system.md §8 step 7).
    // The colours of every row go through `k`: the old values with the
    // flag off, cream / aluminium / brass with it on. Toggles become
    // levers (`DeckLeverToggleStyle`); the section headers become
    // ledges.
    @ObservedObject private var featureFlags = FeatureFlags.shared
    @Environment(\.dismiss) private var dismiss
    private var deck: Bool { featureFlags.turntableHome }
    private var k: SettingsInk { SettingsInk(deck: deck) }

    /// A section's header: a ledge on the Deck, the old coloured
    /// capitals otherwise.
    @ViewBuilder
    private func sectionHeader(_ title: String, _ color: Color) -> some View {
        if deck {
            DeckLedge(title: title)
                .textCase(nil)
                .padding(.vertical, 6)
        } else {
            Text(title)
                .font(Typography.sectionHeader)
                .foregroundColor(color)
                .textCase(.uppercase)
        }
    }

    /// Deck: a metal back button and the name in print. No bar.
    private var deckHeader: some View {
        HStack(spacing: 4) {
            DeckMetalButton(symbol: "chevron.left", size: 30) {
                HapticManager.light()
                dismiss()
            }
            .accessibilityLabel("Back")
            Text("Settings")
                .font(DeckType.screenTitle)
                .foregroundColor(TurntableTokens.cream)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // S18 / v1.6.1: dynamic version string read from the bundle.
    // Returns "1.6.0 (12)" — the marketing version plus the build
    // number in parens, which is the conventional App Store format
    // and makes "is the build the user is on newer than what I
    // think" obvious at a glance. Falls back to "—" if the
    // bundle is somehow missing the keys (should never happen in
    // a real .app, but defensive is cheap).
    private var appVersionString: String {
        let dict = Bundle.main.infoDictionary
        let short = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String
        if let build = build, !build.isEmpty {
            return "\(short) (\(build))"
        }
        return short
    }
    @State private var newArtistText: String = ""
    // S15: editable backend host. Persisted to UserDefaults under
    // APIService.baseURLOverrideDefaultsKey and read on the
    // next launch (or immediately on save).
    @State private var serverHostDraft: String = UserDefaults.standard.string(forKey: APIService.baseURLOverrideDefaultsKey) ?? ""
    // S17-H (round 5): tick that increments on Save so the
    // "Backend Host" display (Text(APIService.shared.baseURL))
    // re-renders. Without this, SwiftUI doesn't know to redraw the
    // display when UserDefaults is mutated by the Save button —
    // the @State `serverHostDraft` only drives the TextField below
    // it, not the read-only display above. Result: user sees the
    // old value in the display, assumes the Save was a no-op, taps
    // Save again. The tick + an .id() modifier here forces a
    // re-render and the display reflects the new override
    // immediately.
    @State private var savedTick: Int = 0
    // S17 (CV-4): "Test connection" button state. .idle = no
    // test yet, .testing = request in flight, .ok = 200 with
    // latency, .error = non-200 or transport failure. The Task
    // is held in `connectionTestTask` so the view can cancel it
    // on disappear.
    @State private var connectionTest: ConnectionTestState = .idle
    @State private var connectionTestTask: Task<Void, Never>?
    // S15: 10-band EQ status line for the Settings row.
    @ObservedObject private var eq = AudioEqualizer.shared

    private enum ConnectionTestState: Equatable {
        case idle
        case testing
        case ok(latencyMs: Int)
        case error(String)

        var isTesting: Bool {
            if case .testing = self { return true }
            return false
        }
    }

    /// One-line status for the EQ row in the Audio section.
    /// Shows the active preset when the EQ is on, otherwise
    /// "Off".
    private var eqStatusLine: String {
        if !eq.isEnabled { return "Off" }
        let preset = eq.preset.rawValue
        if preset == "Custom" { return "On · Custom" }
        return "On · \(preset)"
    }

    /// 2026-08-12: Smart Library status line for the
    /// "Auto-download on WiFi" toggle. Shows the last-run
    /// time + track count if we've ever run. Otherwise
    /// "Off" (toggle disabled) or "Ready" (first run
    /// pending). Mirrors the concise style of the other
    /// Settings status lines.
    ///
    /// v1.8.2: if the last run was SKIPPED (e.g. library
    /// full), show the skip reason in orange instead of
    /// the normal "Last: ..." line. This is the
    /// user-visible answer to "why didn't anything
    /// download when I opened the app?".
    private var autoDownloadStatusLine: String {
        if !smartLibrary.autoDownloadEnabled { return "Off" }
        if smartLibrary.isAutoDownloading { return "Auto-downloading…" }
        if let skip = smartLibrary.lastAutoDownloadSkippedReason {
            return "Skipped: \(skip)"
        }
        guard let last = smartLibrary.lastAutoDownloadAt else { return "Ready" }
        return "Last: \(formatRelative(last)) · \(smartLibrary.lastAutoDownloadCount) track\(smartLibrary.lastAutoDownloadCount == 1 ? "" : "s")"
    }

    /// 2026-08-12 v1.8.2: live library count. Used in the
    /// section header ("X / N") and the Refresh alert
    /// ("This will remove all X downloaded tracks…").
    /// Reads from CoreData each time the view renders —
    /// cheap (one count(for:) call, ~ms) and avoids
    /// any cross-component state-sync concerns.
    private var libraryCount: Int {
        smartLibrary.currentDownloadedTrackCount()
    }

    /// 2026-08-12: Smart Library status line for the
    /// "Auto-cleanup" toggle. Shows the last cleanup time
    /// + count + bytes freed. Mirrors autoDownloadStatusLine.
    private var cleanupStatusLine: String {
        if !smartLibrary.cleanupEnabled { return "Off" }
        if smartLibrary.isCleaningUp { return "Cleaning up…" }
        guard let last = smartLibrary.lastCleanupAt else {
            return "Ready · auto \(smartLibrary.cleanupDaysAuto)d · manual \(smartLibrary.cleanupDaysManual)d"
        }
        let mb = ByteCountFormatter.string(fromByteCount: smartLibrary.lastCleanupBytesFreed, countStyle: .file)
        return "Last: \(formatRelative(last)) · \(smartLibrary.lastCleanupCount) · \(mb)"
    }

    /// 2026-10-02: computed out of the ViewBuilder because the inline
    /// ByteCountFormatter call made the expression too complex for the type
    /// checker to resolve in reasonable time.
    private var emergencyCleanupExplainer: String {
        let threshold = ByteCountFormatter.string(
            fromByteCount: Int64(smartLibrary.emergencyThresholdBytes), countStyle: .file)
        return "Off: nothing is deleted until its trash period ends. "
             + "On: below \(threshold) free, tracks are deleted permanently with "
             + "no trash, no undo and no confirmation."
    }

    /// v1.9.0: status line for the "Auto-confirm after"
    /// picker. Explains what the selected value means
    /// in user terms — "card auto-closes in 5 min" reads
    /// better than just "5 min" next to a toggle the user
    /// didn't ask for.
    private var autoConfirmLabel: String {
        let s = smartLibrary.autoConfirmSeconds
        if s == 0 { return "Card stays open until you act" }
        if s < 60 { return "Card auto-closes in \(s)s" }
        let mins = s / 60
        return "Card auto-closes in \(mins) min"
    }

    /// v1.9.0 (r5): dynamic options for the "Candidates per
    /// cycle" Picker. The Picker must always offer values
    /// strictly less than the current "Library limit" —
    /// otherwise the per-cycle batch would equal or
    /// exceed the total library cap, and the cycle would
    /// always be skipped at the `currentCount >= maxLibraryTracks`
    /// check in `runAutoDownloadCycle`.
    ///
    /// The base option set is [10, 20, 30, 50, 100]. The
    /// computed list filters out anything >= maxLibraryTracks
    /// and ensures the current value is always selectable
    /// (defensive — the .onChange below should keep them
    /// in sync, but a stale value from a fresh install
    /// shouldn't crash the Picker).
    private var candidateCapOptions: [Int] {
        let allOptions = [10, 20, 30, 50, 100]
        let filtered = allOptions.filter { $0 < smartLibrary.maxLibraryTracks }
        if filtered.contains(smartLibrary.autoDownloadMaxPerCycle) {
            return filtered
        }
        // Current value isn't in the filtered list — append
        // it so the Picker still shows the active value.
        // This shouldn't happen post-clamp but guards
        // against a stale UserDefaults value on a fresh
        // install with a small library limit.
        return filtered + [smartLibrary.autoDownloadMaxPerCycle]
    }

    /// v1.9.0 (r5): when maxLibraryTracks changes, clamp
    /// autoDownloadMaxPerCycle to the largest valid option
    /// if it would otherwise be >= the new limit. Without
    /// this, the user could have a 50-track library with
    /// a 50-per-cycle cap, then change the library cap
    /// to 25 — leaving a 50-per-cycle cap that would
    /// immediately fail the `currentCount >= maxLibraryTracks`
    /// check in runAutoDownloadCycle and never run again.
    private func clampCandidateCapIfNeeded(newLimit: Int) {
        if smartLibrary.autoDownloadMaxPerCycle >= newLimit {
            let valid = candidateCapOptions.filter { $0 < newLimit }
            if let clamped = valid.max() {
                smartLibrary.autoDownloadMaxPerCycle = clamped
            }
        }
    }

    /// "5m ago" / "2h ago" / "3d ago" — used by both Smart
    /// Library status lines. Caps at "1y+" for ancient
    /// timestamps (which shouldn't happen in practice but
    /// defensive is cheap).
    private func formatRelative(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        if elapsed < 86400 * 7 { return "\(Int(elapsed / 86400))d ago" }
        if elapsed < 86400 * 30 { return "\(Int(elapsed / (86400 * 7)))w ago" }
        return "1y+ ago"
    }

    /// S17 (CV-4): title for the "Test connection" button
    /// depends on the current state. idle → "Test connection",
    /// testing → "Testing…", ok → "OK · Nms", error →
    /// "Failed: <message>". S17-H (round 7): show up to 200
    /// chars so the user can actually read the iOS URLSession
    /// error — the previous 40-char cap truncated the
    /// NSURLError localizedDescription to "The resource could
    /// not be loaded because..." which is useless for diagnosis.
    private var connectionTestButtonTitle: String {
        switch connectionTest {
        case .idle:
            return "Test connection"
        case .testing:
            return "Testing…"
        case .ok(let ms):
            return "OK · \(ms)ms"
        case .error(let msg):
            // 200 char cap + a tap-to-copy hint
            let trimmed = msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
            return "Failed: \(trimmed) (tap to copy)"
        }
    }

    /// S17 (CV-4): do a GET /health with a 5s timeout. The
    /// result is recorded in `connectionTest`. We
    /// deliberately do NOT add the Bearer token so the test
    /// reflects reachability, not auth state — GET /health is
    /// intentionally open (no auth) on the backend.
    private func runConnectionTest() {
        connectionTestTask?.cancel()
        connectionTest = .testing

        let urlString = APIService.shared.baseURL + "/health"
        guard let url = URL(string: urlString) else {
            connectionTest = .error("Invalid URL")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "GET"

        connectionTestTask = Task { @MainActor in
            let started = Date()
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if Task.isCancelled { return }
                guard let http = response as? HTTPURLResponse else {
                    connectionTest = .error("Not HTTP")
                    return
                }
                let latency = Int(Date().timeIntervalSince(started) * 1000)
                if http.statusCode == 200 {
                    connectionTest = .ok(latencyMs: latency)
                    HapticManager.success()
                } else {
                    connectionTest = .error("HTTP \(http.statusCode)")
                    HapticManager.error()
                }
            } catch {
                if Task.isCancelled { return }
                let msg: String
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .timedOut: msg = "Timed out (5s)"
                    case .cannotFindHost: msg = "Host not found"
                    case .cannotConnectToHost: msg = "Connection refused"
                    case .networkConnectionLost: msg = "Network lost"
                    case .notConnectedToInternet: msg = "Offline"
                    default: msg = urlError.localizedDescription
                    }
                } else {
                    msg = error.localizedDescription
                }
                connectionTest = .error(msg)
                HapticManager.error()
            }
        }
    }

    var body: some View {
        // S14: Settings now lives inside Home's NavigationStack when
        // pushed from the Home header chip. The standard nav bar (with
        // back button) replaces the previous "sheet that had no nav
        // chrome and looked like a black bar". The 24pt top spacer is
        // reduced to 8pt because the nav bar already provides top
        // padding; the extra 24pt only made sense under a bare sheet.
        ZStack {
            if deck {
                DeckRoom()
            } else {
                Theme.cyberBackground.ignoresSafeArea()
            }

            VStack(spacing: 0) {
                if deck {
                    deckHeader
                } else {
                    Color.clear.frame(height: 8)
                }
            List {
                // MARK: - Account Section (S13)
                // S13: Account actions belong at the top of Settings, not
                // buried at the bottom. Currently shows the signed-in
                // identifier (email if known, userId fallback) and a
                // destructive Sign Out row. Tapping Sign Out fires a
                // confirmation, then calls AuthService.signOut() (which
                // clears Keychain + SyncService.handleSignOut) and
                // WidgetSyncService.reloadAll() so lock-screen / home
                // widgets don't show stale Now Playing.
                Section {
                    Button {
                        showProfileSheet = true
                    } label: {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(k.accent.opacity(0.2))
                                    .frame(width: 44, height: 44)

                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(k.accent)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(auth.email ?? auth.userId ?? "Signed In")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(k.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Text("Apple ID")
                                    .font(.caption)
                                    .foregroundColor(k.ok)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(k.dim)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .listRowBackground(k.rowBG)
                    .accessibilityLabel("Profile and sign out")

                    Button {
                        showSignOutConfirmation = true
                    } label: {
                        HStack(spacing: 12) {
                            if isSigningOut {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(k.destructive)
                            } else {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .foregroundColor(k.destructive)
                            }
                            Text(isSigningOut ? "Signing Out…" : "Sign Out")
                                .foregroundColor(k.destructive)
                        }
                    }
                    .disabled(isSigningOut)
                    .listRowBackground(k.rowBG)
                } header: {
                    sectionHeader("Account", k.accent)
                }

                BackupStatusSection()

                // MARK: - Audio Section (S13)
                // S13: Audio settings (Crossfade, Gapless, Adaptive Walk
                // DJ, Loudness Normalization) were only reachable via a
                // deep button inside the FullPlayer's more-actions row.
                // This row surfaces them at the top level of Settings.
                // AudioSettingsView lives inside FullPlayer.swift but is
                // already default-internal, so we can present it here
                // without extracting or duplicating the file.
                Section {
                    Button {
                        showAudioSettings = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(k.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Audio")
                                    .foregroundColor(k.ink)
                                Text("Crossfade, gapless, loudness")
                                    .font(.caption)
                                    .foregroundColor(k.dim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(k.dim)
                        }
                    }
                    .listRowBackground(k.rowBG)
                    // S15: real EQ panel — 10-band parametric EQ with
                    // 8 presets (Flat / Bass Boost / Treble Boost /
                    // Vocal / Electronic / Hip-Hop / Rock / Acoustic)
                    // and per-band sliders. Biquad cascade applied
                    // in real time to the audio output via the
                    // visualizer tap.
                    Button {
                        showEqualizer = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.vertical.3")
                                .foregroundColor(k.warm)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Equalizer")
                                        .foregroundColor(k.ink)
                                    if AudioEqualizer.shared.isEnabled {
                                        Text("ON")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(.black)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(k.accent)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(eqStatusLine)
                                    .font(.caption)
                                    .foregroundColor(k.dim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(k.dim)
                        }
                    }
                    .listRowBackground(k.rowBG)
                } header: {
                    sectionHeader("Audio", k.accent)
                }

                // MARK: - Accessibility Section (S18 / P0-2)
                // Haptic Symphony runs a 30fps Core Haptics driver for
                // the full duration of playback. For users with
                // vestibular sensitivity, epilepsy, or a Core-Haptics
                // triggering medical device, this can be uncomfortable
                // or unsafe. Provide a single "Reduce Haptics" toggle
                // that gates the engine (defers to system Reduce Motion
                // when no explicit setting is present).
                Section {
                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: HapticSymphonyEngine.reducePreferenceKey) },
                        set: { newValue in
                            UserDefaults.standard.set(newValue, forKey: HapticSymphonyEngine.reducePreferenceKey)
                            // If the user just turned OFF reduce, they
                            // may have left the engine running (the
                            // previous state was suppressed). Start
                            // it now if a track is playing and the
                            // device supports haptics.
                            if !newValue,
                               HapticSymphonyEngine.shared.isSupported,
                               HapticSymphonyEngine.shared.canStart,
                               PlayerState.shared.playbackState == .playing {
                                HapticSymphonyEngine.shared.start()
                            }
                            // If the user just turned ON reduce, stop
                            // the engine immediately.
                            if newValue, HapticSymphonyEngine.shared.isActive {
                                HapticSymphonyEngine.shared.stop()
                            }
                        }
                    )) {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.raised.slash.fill")
                                .foregroundColor(k.warm)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reduce Haptics")
                                    .foregroundColor(k.ink)
                                Text("Suppress Haptic Symphony in the player")
                                    .font(.caption)
                                    .foregroundColor(k.dim)
                            }
                        }
                    }
                    .listRowBackground(k.rowBG)
                } header: {
                    sectionHeader("Accessibility", k.accent)
                }

                // MARK: - Labs Section (S18 / v1.6)
                // Feature flags. Each toggle is opt-in so the user
                // can decide whether to enable experimental /
                // risky behaviors. Defaults match the shipping
                // v1.5 state.
                Section {
                    LabsToggle(
                        key: "ff_on_this_day",
                        defaultValue: false,
                        icon: "calendar",
                        iconColor: k.warm,
                        title: "On This Day",
                        subtitle: "Show tracks you played on this day in prior years"
                    )
                    LabsToggle(
                        key: "ff_capsule_prewarn",
                        defaultValue: false,
                        icon: "bell.badge",
                        iconColor: k.warm,
                        title: "Capsule Pre-Warning",
                        subtitle: "Notify 7 days before a Time Capsule unlocks"
                    )
                    LabsToggle(
                        key: "ff_daily_recap",
                        defaultValue: false,
                        icon: "clock.arrow.circlepath",
                        iconColor: k.accent,
                        title: "Daily Recap",
                        subtitle: "If you haven't played in 24h, remind you of your last track",
                        // When the user flips the toggle, the notifier
                        // cancels any pending recap (if turning OFF) or
                        // clears the "permanently disabled by 3
                        // consecutive play days" flag (if turning ON).
                        onChange: { enabled in
                            DailyRecapNotifier.shared.handleFlagChange(enabled: enabled)
                        }
                    )
                    LabsToggle(
                        key: "ff_cross_feature_wiring",
                        defaultValue: true,
                        icon: "antenna.radiowaves.left.and.right",
                        iconColor: k.warm,
                        title: "Memory-Boosted Anti-Algorithm",
                        subtitle: "Songs you've written memories for are seeded more often"
                    )
                    // 2026-11-17: the Turntable Home. The record is the
                    // home screen - platter, tonearm, cue lever, crate.
                    // Default OFF so no existing user's entry screen
                    // changes until they opt in.
                    //
                    // `onChange` mirrors the value into FeatureFlags.
                    // The flag has to be read in two places (HomeView
                    // swaps the body, ContentView hides the MiniPlayer)
                    // and a cached read in either would leave them out
                    // of sync after a toggle.
                    LabsToggle(
                        key: FeatureFlags.turntableHomeKey,
                        defaultValue: false,
                        icon: "record.circle",
                        iconColor: k.accent,
                        title: "Turntable Home",
                        subtitle: "Replace the home screen with a record deck",
                        onChange: { enabled in
                            FeatureFlags.shared.turntableHome = enabled
                        }
                    )
                } header: {
                    sectionHeader("Labs", k.warm)
                } footer: {
                    Text("Experimental features. Each toggle is independent.")
                        .font(.caption)
                        .foregroundColor(k.secondary)
                }

                // MARK: - Music Sources Section
                Section {
                    // YouTube (always active)
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(k.youtube.opacity(0.2))
                                .frame(width: 44, height: 44)

                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(k.youtube)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("YouTube")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(k.ink)

                            Text("Active")
                                .font(.caption)
                                .foregroundColor(k.ok)
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(k.ok)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(k.rowBG)
                } header: {
                    sectionHeader("Music Sources", k.accent)
                }

                // MARK: - Favorite Artists Section
                // 2026-06-28: redesigned. The old layout was a flat
                // List of rows that read like a phonebook. The new
                // layout shows each artist as a neon chip with an
                // embedded remove button (×), the artists wrap into a
                // flow via a custom flow layout, and the add control
                // is a text field with a neon "ADD" button. The
                // empty state is friendlier (a glowing mic icon and a
                // single-line hint instead of three dim lines).
                Section {
                    if favoriteArtists.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 12) {
                                Image(systemName: "music.mic")
                                    .font(.system(size: 32))
                                    .foregroundColor(k.accent)
                                    .glow(color: k.accent, radius: deck ? 0 : 10)
                                Text("No favorites yet")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(k.ink)
                                Text("Add artists you love to personalize Home")
                                    .font(.system(size: 12))
                                    .foregroundColor(k.dim)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, 24)
                            .padding(.horizontal, 16)
                            Spacer()
                        }
                        .listRowBackground(k.rowBG)
                    } else {
                        // Wrap chips into a flow layout (iOS doesn't
                        // ship one, so we use a simple width-tracking
                        // HStack/VStack combo).
                        FavoriteArtistFlowLayout(artists: favoriteArtists.artists) { artist in
                            FavoriteArtistChip(
                                artist: artist,
                                onRemove: { removeArtist(artist) }
                            )
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(k.rowBG)
                    }

                    // Add row — neon-bordered field + cyan add button
                    if deck {
                        // Deck: the name lies in a well; Add is a key.
                        HStack(spacing: 10) {
                            TextField("", text: $newArtistText,
                                      prompt: Text("Add artist or genre").foregroundColor(TurntableTokens.cream.opacity(0.4)))
                                .font(DeckType.body)
                                .foregroundColor(TurntableTokens.cream)
                                .tint(DeckSignal.live)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .onSubmit { addArtist() }
                                .padding(.horizontal, 18)
                                .frame(height: 48)
                                .deckWell(Capsule())

                            DeckButton(title: "Add") { addArtist() }
                                .disabled(newArtistText.isEmpty)
                                .opacity(newArtistText.isEmpty ? 0.45 : 1)
                        }
                        .listRowBackground(k.rowBG)
                        .listRowSeparator(.hidden)
                    } else {
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(k.accent)
                            TextField("Add artist or genre...", text: $newArtistText)
                                .textFieldStyle(.neon)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.words)
                                .onSubmit { addArtist() }
                        }

                        Button {
                            addArtist()
                        } label: {
                            Text("ADD")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(newArtistText.isEmpty ? k.dim : Theme.cyberBackground)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(newArtistText.isEmpty ? k.rowBG : k.accent)
                                )
                        }
                        .disabled(newArtistText.isEmpty)
                    }
                    .listRowBackground(k.rowBG)
                    }
                } header: {
                    if deck {
                        DeckLedge(title: "Favorite artists", count: favoriteArtists.artists.count)
                            .textCase(nil)
                            .padding(.vertical, 6)
                    } else {
                    HStack {
                        Image(systemName: "music.mic")
                            .foregroundColor(k.warm)
                        sectionHeader("Favorite Artists", k.accent)
                    }
                    }
                } footer: {
                    Text("Get personalized track suggestions on the Home screen based on your favorite artists and genres.")
                        .font(.system(size: 11))
                        .foregroundColor(k.dim)
                }

                // MARK: - Storage Section
                Section {
                    HStack {
                        Label {
                            Text("Cache Size")
                        } icon: {
                            Image(systemName: "externaldrive.fill")
                                .foregroundColor(k.accent)
                        }
                        .foregroundColor(k.ink)

                        Spacer()

                        Text(cacheSize)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .listRowBackground(k.rowBG)

                    Button {
                        showClearCacheConfirmation = true
                    } label: {
                        Label {
                            Text("Clear Cache")
                                .foregroundColor(k.destructive)
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundColor(k.destructive)
                        }
                    }
                    .listRowBackground(k.rowBG)
                } header: {
                    sectionHeader("Storage", k.accent)
                }

                // MARK: - Smart Library Section
                // 2026-08-12: v1.8.0 — auto-download on WiFi +
                // auto-cleanup of unused downloads. Two
                // independent toggles with status lines that
                // show the last run + result, plus a manual
                // "Clean up now" button for users who don't
                // want to wait for the weekly debounce.
                // 2026-08-12: v1.8.2 — added library limit
                // picker, library-count status, and the
                // "Refresh downloads" button with confirmation.
                Section {
                    // 2026-10-02: the control for cleanupEnabled. The flag was
                    // readable in three guards and a status line that was itself
                    // never rendered -- cleanup ran with no way to stop it.
                    // Off by default; the emergency sub-toggle below is separate
                    // because that path deletes permanently.
                    Toggle(isOn: $smartLibrary.cleanupEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(k.accent)
                                Text("Auto-cleanup library")
                                    .foregroundColor(k.ink)
                            }
                            Text(cleanupStatusLine)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(k.secondary)
                        }
                    }
                    .tint(k.accent)
                    .listRowBackground(k.rowBG)

                    if smartLibrary.cleanupEnabled {
                        Toggle(isOn: $smartLibrary.emergencyCleanupEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(k.caution)
                                    Text("Delete immediately when storage is low")
                                        .foregroundColor(k.ink)
                                }
                                Text(emergencyCleanupExplainer)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(k.secondary)
                            }
                        }
                        .tint(.orange)
                        .listRowBackground(k.rowBG)
                    }

                    // Auto-download on WiFi
                    Toggle(isOn: $smartLibrary.autoDownloadEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "wifi")
                                    .foregroundColor(k.accent)
                                Text("Auto-download on WiFi")
                                    .foregroundColor(k.ink)
                            }
                            Text(autoDownloadStatusLine)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(k.secondary)
                        }
                    }
                    .listRowBackground(k.rowBG)

                    // v1.8.2: Library limit picker. Pinned
                    // options (25/50/100/200/500) instead of a
                    // free-form Stepper — gives clean breakpoints
                    // and predictable behavior. Default 50 is the
                    // v1.8.2 ship default.
                    HStack {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                            .foregroundColor(k.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Library limit")
                                .foregroundColor(k.ink)
                            Text("\(smartLibrary.maxLibraryTracks) tracks")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(k.secondary)
                        }
                        Spacer()
                        Picker("", selection: $smartLibrary.maxLibraryTracks) {
                            ForEach([25, 50, 100, 200, 500], id: \.self) { limit in
                                Text("\(limit)").tag(limit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(k.accent)
                    }
                    .listRowBackground(k.rowBG)

                    // v1.9.0 (r4 + r5): Per-cycle candidate
                    // count. Distinct from "Library limit"
                    // above — that one caps the TOTAL number
                    // of downloaded tracks (default 50). This
                    // one caps how many candidates the card
                    // offers in a SINGLE cycle (default 20).
                    //
                    // v1.9.0 (r5): the Picker options are
                    // dynamic — computed from candidateCapOptions,
                    // which filters the base set [10, 20, 30,
                    // 50, 100] down to values strictly less
                    // than the current Library limit. If the
                    // user changes the Library limit, the
                    // .onChange below auto-clamps the
                    // candidate cap to the largest valid
                    // option.
                    HStack {
                        Image(systemName: "tray.full")
                            .foregroundColor(k.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Candidates per cycle")
                                .foregroundColor(k.ink)
                            // Sublabel explains the constraint
                            // so the user understands why the
                            // Picker doesn't show 50/100 when
                            // the library limit is 25.
                            Text("Up to \(smartLibrary.autoDownloadMaxPerCycle) · must be < library limit (\(smartLibrary.maxLibraryTracks))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(k.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Picker("", selection: $smartLibrary.autoDownloadMaxPerCycle) {
                            // v1.9.0 (r5): dynamic options,
                            // not the hardcoded [10,20,30,50,100]
                            // from r4. The list adapts to the
                            // current Library limit so the
                            // Picker can never offer an
                            // invalid value.
                            ForEach(candidateCapOptions, id: \.self) { cap in
                                Text("\(cap)").tag(cap)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(k.accent)
                    }
                    .listRowBackground(k.rowBG)
                    // v1.9.0 (r5): when the Library limit
                    // changes, clamp the candidate cap so it
                    // stays strictly less. Without this, a
                    // user with maxLibraryTracks=50 and
                    // autoDownloadMaxPerCycle=50 who changes
                    // the library limit to 25 would leave
                    // a 50-per-cycle cap that immediately
                    // fails the cycle's `currentCount >=
                    // maxLibraryTracks` precondition.
                    .onChange(of: smartLibrary.maxLibraryTracks) { _, newLimit in
                        clampCandidateCapIfNeeded(newLimit: newLimit)
                    }

                    // v1.9.0: Auto-confirm window. How long
                    // the Smart Library card waits before
                    // auto-committing the candidates if the
                    // user doesn't act. Off means the user
                    // must explicitly tap Download or Skip
                    // every cycle (power-user mode).
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(k.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-confirm after")
                                .foregroundColor(k.ink)
                            Text(autoConfirmLabel)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(k.secondary)
                        }
                        Spacer()
                        Picker("", selection: $smartLibrary.autoConfirmSeconds) {
                            // 0 = off. The remaining options
                            // cover "set it and forget it" → "I
                            // want to see every cycle". 5m is
                            // the default.
                            Text("Off").tag(0)
                            Text("1 min").tag(60)
                            Text("5 min").tag(300)
                            Text("15 min").tag(900)
                            Text("30 min").tag(1800)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(k.accent)
                    }
                    .listRowBackground(k.rowBG)

                    // Manual cleanup trigger
                    Button {
                        smartLibrary.runCleanupNow()
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(k.accent)
                            Text("Clean up now")
                                .foregroundColor(k.ink)
                            Spacer()
                            if smartLibrary.isCleaningUp {
                                ProgressView()
                                    .tint(k.accent)
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(smartLibrary.isCleaningUp)
                    .listRowBackground(k.rowBG)

                    // 2026-09-08: v1.9.3 Trash. The ask-
                    // before-cleanup flow moves files here
                    // (recoverable for 7d) instead of deleting
                    // them outright. Surface a NavigationLink
                    // whenever there's anything recoverable,
                    // so the user can find their way back to
                    // a "whoops I didn't mean to" track.
                    NavigationLink {
                        TrashView()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                                .foregroundColor(k.warm)
                            Text("Trash")
                                .foregroundColor(k.ink)
                            Spacer()
                            if smartLibrary.trashBytes > 0 {
                                Text(byteString(smartLibrary.trashBytes))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(k.warm)
                            } else {
                                Text("Empty")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(k.secondary)
                            }
                        }
                    }
                    .listRowBackground(k.rowBG)

                    // v1.8.2: Refresh downloads. Destructive
                    // action (deletes ALL current downloads,
                    // then re-derives from history). Gated by
                    // a confirmation alert — we don't want
                    // accidental taps nuking someone's library.
                    Button(role: .destructive) {
                        showRefreshConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(k.warm)
                            Text("Refresh downloads")
                                .foregroundColor(k.ink)
                            Spacer()
                            if smartLibrary.isRefreshing {
                                ProgressView()
                                    .tint(k.warm)
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(smartLibrary.isRefreshing)
                    .listRowBackground(k.rowBG)
                } header: {
                    if deck {
                        DeckLedge(title: "Smart library", count: libraryCount)
                            .textCase(nil)
                            .padding(.vertical, 6)
                    } else {
                    HStack {
                        sectionHeader("Smart Library", k.accent)
                        Spacer()
                        // v1.8.2: live library count in the
                        // section header. Shows "X / N" so the
                        // user always sees their current fill
                        // level vs the configured limit. Updates
                        // on every render (the SmartLibraryManager
                        // is @StateObject so the section re-renders
                        // on any @Published change).
                        Text("\(libraryCount) / \(smartLibrary.maxLibraryTracks)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(
                                libraryCount >= smartLibrary.maxLibraryTracks
                                    ? k.warm
                                    : k.secondary
                            )
                    }
                    }
                } footer: {
                    Text("Auto-downloads: new releases from your favorite artists + recently-played tracks. The library is capped at the chosen limit — auto-downloads skip when full, and the Refresh button clears and re-derives from your current history. Auto-cleanup: removes liked-never, auto-downloads after \(smartLibrary.cleanupDaysAuto)d unplayed, manual downloads after \(smartLibrary.cleanupDaysManual)d.")
                        .font(.system(size: 11))
                        .foregroundColor(k.secondary)
                }
                // v1.8.2: confirmation alert for Refresh.
                // Destructive button role above + the alert
                // here = double guard against accidental taps.
                // v1.9.0: the message now shows the concrete
                // count of liked tracks that will be deleted,
                // so the user can see the real cost of the
                // refresh before confirming. Previously the
                // message said "liked tracks will need to be
                // re-liked" without saying how many — easy to
                // dismiss until you realise you had 47 liked
                // tracks and now they're all gone.
                .alert("Refresh downloads?", isPresented: $showRefreshConfirm) {
                    Button("Refresh", role: .destructive) {
                        smartLibrary.runRefreshNow()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    let likedCount = smartLibrary.likedDownloadedCount()
                    if likedCount == 0 {
                        Text("This will remove all \(libraryCount) downloaded tracks and re-download based on your recent history.")
                    } else {
                        Text("This will remove all \(libraryCount) downloaded tracks, including \(likedCount) liked \(likedCount == 1 ? "track" : "tracks"). You'll need to re-like them after the refresh if you want them kept long-term.")
                    }
                }

                Section {
                    Button("Configure backend server") { showBackendSettings = true }
                    Text(BackendConfiguration.shared.identity.origin.absoluteString)
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    sectionHeader("Backend", k.accent)
                }

                // MARK: - About Section
                Section {
                    HStack {
                        Label {
                            Text("Version")
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(k.accent)
                        }
                        .foregroundColor(k.ink)

                        Spacer()

                        // S18 / v1.6.1: read the marketing version
                        // (CFBundleShortVersionString, e.g. "1.6.0")
                        // and the build number (CFBundleVersion, e.g.
                        // "12") straight from the bundle. The old
                        // hardcoded "1.0.0" only updated when someone
                        // remembered to edit this string, which had
                        // drifted from the actual shipping version
                        // for the last several releases.
                        Text(appVersionString)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .listRowBackground(k.rowBG)
                } header: {
                    sectionHeader("About", k.accent)
                }
            }
            .scrollContentBackground(deck ? .hidden : .automatic)
            .listRowSeparatorTint(deck ? TurntableTokens.cream.opacity(0.08) : nil)
            .modifier(DeckSettingsStyle(deck: deck))
            .background(k.wall)
            }
        }
        .confirmationDialog(
            "Clear Cache?",
            isPresented: $showClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                clearCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all cached artwork and temporary files. Your downloaded music will not be affected.")
        }
        // S13: Sign Out confirmation — destructive action that requires
        // explicit user consent. We don't ask for account password since
        // AuthService.signOut() posts to /auth/signout with the bearer
        // token (a logout clears the local Keychain + revokes the server
        // session in one step). After sign-out completes we reload all
        // widgets so home / lock-screen widgets don't show stale data.
        .confirmationDialog(
            "Sign Out?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await performSignOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your downloads stay on this device, but you'll need to sign in again to sync.")
        }
        .onAppear {
            calculateCacheSize()
            // v1.9.0 (r5): clamp a stale candidate cap
            // (e.g. from v1.9.0 r4 with maxLibraryTracks=25
            // and autoDownloadMaxPerCycle=50) on first
            // appearance. The Picker also handles this
            // for in-app changes; this catches the
            // cross-version upgrade case.
            clampCandidateCapIfNeeded(newLimit: smartLibrary.maxLibraryTracks)
        }
        .preferredColorScheme(.dark)
        // S14: standard nav chrome when pushed into Home's
        // NavigationStack. `.navigationTitle` shows in the system
        // nav bar; the back button is auto-provided.
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(deck ? .hidden : .visible, for: .navigationBar)
        .environment(\.deckStyle, deck)
        // S13: Audio settings sheet (reuses AudioSettingsView defined in
        // FullPlayer.swift — default-internal struct, no extraction
        // needed).
        .sheet(isPresented: $showBackendSettings) { BackendSettingsView() }
        .sheet(isPresented: $showAudioSettings) {
            AudioSettingsView()
                .preferredColorScheme(.dark)
        }
        // S15: 10-band parametric EQ panel.
        .sheet(isPresented: $showEqualizer) {
            EqualizerPanelView()
                .preferredColorScheme(.dark)
        }
        // 2026-11-18: the avatar / display-name / sign-out sheet,
        // moved here from the Home profile chip.
        .sheet(isPresented: $showProfileSheet) {
            AvatarPickerSheet()
                .preferredColorScheme(.dark)
        }
        // S17 (CV-4): cancel any in-flight connection
        // test when the Settings view is dismissed so we
        // don't try to update state on a torn-down view.
        .onDisappear {
            connectionTestTask?.cancel()
            connectionTestTask = nil
            connectionTest = .idle
        }
    }

    // S13: Async sign-out flow. Wraps AuthService.signOut() (which posts
    // to backend, clears Keychain, and calls SyncService.handleSignOut),
    // then reloads widget timelines. ContentView observes
    // auth.isAuthenticated and flips back to LandingView automatically.
    private func performSignOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        await AuthService.shared.signOut()
        WidgetSyncService.reloadAll()
        HapticManager.medium()
    }

    private func calculateCacheSize() {
        let size = ImageCache.shared.cacheSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        cacheSize = formatter.string(fromByteCount: Int64(size))
    }

    /// 2026-09-08: small helper for the Trash row's "X MB
    /// recoverable" line. Same formatter style as the rest
    /// of Settings.
    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func clearCache() {
        ImageCache.shared.clearCache()
        calculateCacheSize()
    }

    private func addArtist() {
        let trimmed = newArtistText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        favoriteArtists.addArtist(trimmed)
        newArtistText = ""
        HapticManager.light()
    }

    private func deleteArtist(at offsets: IndexSet) {
        favoriteArtists.removeArtist(at: offsets)
        HapticManager.light()
    }

    // 2026-06-28: per-chip remove. Called from the new chip UI;
    // deleteArtist(at:) is still around for swipe-to-delete on the
    // list fallback (and as a safety net).
    private func removeArtist(_ artist: String) {
        favoriteArtists.removeArtist(artist)
        HapticManager.light()
    }
}

// MARK: - Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}

// MARK: - Favorite Artist Chip (2026-06-28 redesign)
// A neon-bordered pill with the artist name and an embedded × button.
// Tapping × removes the artist; tapping the body has no effect (the
// chip is informational, not actionable).
struct FavoriteArtistChip: View {
    let artist: String
    let onRemove: () -> Void

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: the name in print in a well, with a small metal-grey ×.
    private var deckBody: some View {
        HStack(spacing: 4) {
            Text(artist)
                .font(DeckType.subtitle)
                .foregroundColor(TurntableTokens.cream)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 14)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(artist)")
        }
        .frame(height: 34)
        .deckWell(Capsule())
    }

    private var legacyBody: some View {
        HStack(spacing: 8) {
            Text(artist)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.cyberCyan)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Theme.cyberCyan.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(artist)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Theme.cyberBackground)
                .overlay(
                    Capsule()
                        .stroke(Theme.cyberCyan.opacity(0.4), lineWidth: 1)
                )
        )
    }
}

// MARK: - Favorite Artist Flow Layout
// SwiftUI doesn't ship a wrap layout, so we build a simple one: lay
// chips left-to-right, breaking to a new row when the running width
// exceeds the parent. Recomputes on every layout pass.
struct FavoriteArtistFlowLayout: View {
    let artists: [String]
    let onRemove: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            self.layout(in: geo.size.width)
        }
        .frame(minHeight: 1)
        // GeometryReader's intrinsic size is otherwise zero — force at
        // least one row of chips to show.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func layout(in totalWidth: CGFloat) -> some View {
        var rows: [[String]] = [[]]
        var currentWidth: CGFloat = 0
        let spacing: CGFloat = 8

        for artist in artists {
            // Approximate chip width: 12pt padding × 2 + 8pt × 2 + text + × button.
            // 8pt per character is a fair estimate for SF Pro 13pt semibold.
            let estimated = CGFloat(artist.count) * 8 + 12 * 2 + 8 * 2 + 18 + 8
            if currentWidth + estimated > totalWidth, !rows[rows.count - 1].isEmpty {
                rows.append([artist])
                currentWidth = estimated + spacing
            } else {
                rows[rows.count - 1].append(artist)
                currentWidth += estimated + spacing
            }
        }

        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { artist in
                        FavoriteArtistChip(artist: artist, onRemove: { onRemove(artist) })
                    }
                }
            }
        }
    }
}

// MARK: - Labs Toggle
// S18 / v1.6: small row used by the Labs section. Binds a
// UserDefaults key to a Toggle so the user can flip feature
// flags without a code change. `defaultValue` is the initial
// value when the key is absent and the value the rest of the
// app sees via UserDefaults.standard.bool(forKey:).
//
// Optional `onChange` closure fires AFTER the value is written
// to UserDefaults, so subscribers can re-evaluate derived state
// (e.g. DailyRecapNotifier clears its permanent-disable flag
// when the user re-enables ff_daily_recap).
private struct LabsToggle: View {
    let key: String
    let defaultValue: Bool
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let onChange: ((Bool) -> Void)?

    @State private var isOn: Bool
    private var k: SettingsInk { SettingsInk(deck: FeatureFlags.shared.turntableHome) }

    init(
        key: String,
        defaultValue: Bool,
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        onChange: ((Bool) -> Void)? = nil
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.onChange = onChange
        // Read the current value from UserDefaults at init.
        // UserDefaults is the source of truth; the rest of
        // the app reads the same key.
        let current = (UserDefaults.standard.object(forKey: key) as? Bool) ?? defaultValue
        self._isOn = State(initialValue: current)
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                isOn = newValue
                UserDefaults.standard.set(newValue, forKey: key)
                onChange?(newValue)
            }
        )) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundColor(k.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(k.secondary)
                }
            }
        }
        .listRowBackground(k.rowBG)
    }
}

// MARK: - Deck tokens

/// The colours of a Settings row. With the turntable flag off these
/// are the old values; on, a row's text is cream, its icons are
/// aluminium or brass (a colour is a lamp, and a row is not on), and
/// destructive rows get no colour of their own.
struct SettingsInk {
    let deck: Bool

    var ink: Color { deck ? TurntableTokens.cream : .white }
    var dim: Color { deck ? TurntableTokens.cream.opacity(0.55) : Theme.cyberDim }
    var secondary: Color { deck ? TurntableTokens.cream.opacity(0.55) : Theme.cyberTextSecondary }
    var accent: Color { deck ? TurntableTokens.aluminium.opacity(0.85) : Theme.cyberCyan }
    var warm: Color { deck ? TurntableTokens.brass : Theme.cyberMagenta }
    var rowBG: Color { deck ? .clear : Theme.cyberSurface }
    var wall: Color { deck ? TurntableTokens.room : Theme.cyberBackground }
    var destructive: Color { deck ? TurntableTokens.cream.opacity(0.9) : Theme.error }
    var ok: Color { deck ? TurntableTokens.brass : .green }
    var caution: Color { deck ? DeckSignal.attention : .orange }
    var youtube: Color { deck ? TurntableTokens.aluminium.opacity(0.85) : .red }
    var headerFont: Font { deck ? DeckType.engraved : Typography.sectionHeader }
}

/// On the Deck every toggle under it is a lever.
private struct DeckSettingsStyle: ViewModifier {
    let deck: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if deck {
            // Plain, not inset-grouped: the grouped style adds ~20pt
            // a side on top of the Deck's own 16pt gutter.
            content
                .listStyle(.plain)
                .toggleStyle(DeckLeverToggleStyle())
        } else {
            content.listStyle(.insetGrouped)
        }
    }
}
