import SwiftUI

struct SettingsView: View {
    @StateObject private var favoriteArtists = FavoriteArtistsManager.shared
    @StateObject private var auth = AuthService.shared
    @State private var showClearCacheConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var showAudioSettings = false  // S13
    @State private var showEqualizer = false  // S15: real 10-band EQ
    @State private var isSigningOut = false
    @State private var cacheSize: String = "Calculating..."
    @State private var newArtistText: String = ""
    // S15: editable backend host. Persisted to UserDefaults under
    // APIService.baseURLOverrideDefaultsKey and read on the
    // next launch (or immediately on save).
    @State private var serverHostDraft: String = UserDefaults.standard.string(forKey: APIService.baseURLOverrideDefaultsKey) ?? ""
    // S15: 10-band EQ status line for the Settings row.
    @ObservedObject private var eq = AudioEqualizer.shared

    /// One-line status for the EQ row in the Audio section.
    /// Shows the active preset when the EQ is on, otherwise
    /// "Off".
    private var eqStatusLine: String {
        if !eq.isEnabled { return "Off" }
        let preset = eq.preset.rawValue
        if preset == "Custom" { return "On · Custom" }
        return "On · \(preset)"
    }

    var body: some View {
        // S14: Settings now lives inside Home's NavigationStack when
        // pushed from the Home header chip. The standard nav bar (with
        // back button) replaces the previous "sheet that had no nav
        // chrome and looked like a black bar". The 24pt top spacer is
        // reduced to 8pt because the nav bar already provides top
        // padding; the extra 24pt only made sense under a bare sheet.
        ZStack {
            Theme.cyberBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Color.clear.frame(height: 8)
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
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Theme.cyberCyan.opacity(0.2))
                                .frame(width: 44, height: 44)

                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(Theme.cyberCyan)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(auth.email ?? auth.userId ?? "Signed In")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text("Apple ID")
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Theme.cyberSurface)

                    Button {
                        showSignOutConfirmation = true
                    } label: {
                        HStack(spacing: 12) {
                            if isSigningOut {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.red)
                            } else {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .foregroundColor(.red)
                            }
                            Text(isSigningOut ? "Signing Out…" : "Sign Out")
                                .foregroundColor(.red)
                        }
                    }
                    .disabled(isSigningOut)
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    Text("Account")
                        .font(Typography.sectionHeader)
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
                }

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
                                .foregroundColor(Theme.cyberCyan)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Audio")
                                    .foregroundColor(.white)
                                Text("Crossfade, gapless, loudness")
                                    .font(.caption)
                                    .foregroundColor(Theme.cyberDim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(Theme.cyberDim)
                        }
                    }
                    .listRowBackground(Theme.cyberSurface)
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
                                .foregroundColor(Theme.cyberMagenta)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Equalizer")
                                        .foregroundColor(.white)
                                    if AudioEqualizer.shared.isEnabled {
                                        Text("ON")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(.black)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Theme.cyberCyan)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(eqStatusLine)
                                    .font(.caption)
                                    .foregroundColor(Theme.cyberDim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(Theme.cyberDim)
                        }
                    }
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    Text("Audio")
                        .font(Typography.sectionHeader)
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
                }

                // MARK: - Music Sources Section
                Section {
                    // YouTube (always active)
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.2))
                                .frame(width: 44, height: 44)

                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.red)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("YouTube")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)

                            Text("Active")
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    Text("Music Sources")
                        .font(Typography.sectionHeader)
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
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
                                    .foregroundColor(Theme.cyberCyan)
                                    .glow(color: Theme.cyberCyan, radius: 10)
                                Text("No favorites yet")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Add artists you love to personalize Home")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.cyberDim)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, 24)
                            .padding(.horizontal, 16)
                            Spacer()
                        }
                        .listRowBackground(Theme.cyberSurface)
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
                        .listRowBackground(Theme.cyberSurface)
                    }

                    // Add row — neon-bordered field + cyan add button
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Theme.cyberCyan)
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
                                .foregroundColor(newArtistText.isEmpty ? Theme.cyberDim : Theme.cyberBackground)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(newArtistText.isEmpty ? Theme.cyberSurface : Theme.cyberCyan)
                                )
                        }
                        .disabled(newArtistText.isEmpty)
                    }
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    HStack {
                        Image(systemName: "music.mic")
                            .foregroundColor(Theme.cyberMagenta)
                        Text("Favorite Artists")
                            .font(Typography.sectionHeader)
                            .foregroundColor(Theme.cyberCyan)
                            .textCase(.uppercase)
                    }
                } footer: {
                    Text("Get personalized track suggestions on the Home screen based on your favorite artists and genres.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.cyberDim)
                }

                // MARK: - Storage Section
                Section {
                    HStack {
                        Label {
                            Text("Cache Size")
                        } icon: {
                            Image(systemName: "externaldrive.fill")
                                .foregroundColor(Theme.cyberCyan)
                        }
                        .foregroundColor(.white)

                        Spacer()

                        Text(cacheSize)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .listRowBackground(Theme.cyberSurface)

                    Button {
                        showClearCacheConfirmation = true
                    } label: {
                        Label {
                            Text("Clear Cache")
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    Text("Storage")
                        .font(Typography.sectionHeader)
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
                }

                // MARK: - Backend Section (S15)
                // S15: editable override for the backend host.
                // Persisted via UserDefaults so a Mac on a different
                // network doesn't require a rebuild. The default
                // (Tailscale IP) is shown in the current value row
                // when the field is empty.
                Section {
                    HStack {
                        Label {
                            Text("Backend Host")
                        } icon: {
                            Image(systemName: "server.rack")
                                .foregroundColor(Theme.cyberCyan)
                        }
                        .foregroundColor(.white)

                        Spacer()

                        Text(APIService.shared.baseURL)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.cyberCyan.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .listRowBackground(Theme.cyberSurface)

                    HStack {
                        Image(systemName: "pencil")
                            .foregroundColor(Theme.cyberCyan)
                            .frame(width: 22)
                        TextField(
                            "e.g. http://192.168.1.10:8181",
                            text: $serverHostDraft
                        )
                        .textFieldStyle(.neon)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        if !serverHostDraft.isEmpty {
                            Button {
                                serverHostDraft = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Theme.cyberSurface)

                    Button {
                        let trimmed = serverHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            UserDefaults.standard.removeObject(forKey: APIService.baseURLOverrideDefaultsKey)
                        } else {
                            UserDefaults.standard.set(trimmed, forKey: APIService.baseURLOverrideDefaultsKey)
                        }
                        HapticManager.success()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Theme.cyberCyan)
                            Text("Save (restart app to apply)")
                                .foregroundColor(.white)
                        }
                    }
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    Text("Backend")
                        .font(Typography.sectionHeader)
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
                } footer: {
                    Text("Override the default backend host. Leave empty to use the built-in default.")
                        .font(.caption)
                        .foregroundColor(Theme.tertiaryText)
                }

                // MARK: - About Section
                Section {
                    HStack {
                        Label {
                            Text("Version")
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(Theme.cyberCyan)
                        }
                        .foregroundColor(.white)

                        Spacer()

                        Text("1.0.0")
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .listRowBackground(Theme.cyberSurface)
                } header: {
                    Text("About")
                        .font(Typography.sectionHeader)
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
                }
            }
            .listStyle(.insetGrouped)
            .background(Theme.cyberBackground)
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
        }
        .preferredColorScheme(.dark)
        // S14: standard nav chrome when pushed into Home's
        // NavigationStack. `.navigationTitle` shows in the system
        // nav bar; the back button is auto-provided.
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // S13: Audio settings sheet (reuses AudioSettingsView defined in
        // FullPlayer.swift — default-internal struct, no extraction
        // needed).
        .sheet(isPresented: $showAudioSettings) {
            AudioSettingsView()
                .preferredColorScheme(.dark)
        }
        // S15: 10-band parametric EQ panel.
        .sheet(isPresented: $showEqualizer) {
            EqualizerPanelView()
                .preferredColorScheme(.dark)
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

    var body: some View {
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
