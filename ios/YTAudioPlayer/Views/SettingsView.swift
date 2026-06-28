import SwiftUI

struct SettingsView: View {
    @StateObject private var favoriteArtists = FavoriteArtistsManager.shared
    @State private var showClearCacheConfirmation = false
    @State private var cacheSize: String = "Calculating..."
    @State private var newArtistText: String = ""

    var body: some View {
        // NOTE: No NavigationView here - ContentView already manages navigation
        ZStack {
            Theme.cyberBackground.ignoresSafeArea()

            List {
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
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
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
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.words)
                                .onSubmit { addArtist() }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Theme.cyberBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Theme.cyberCyan.opacity(0.4), lineWidth: 1)
                                )
                        )

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
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
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
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberCyan)
                        .textCase(.uppercase)
                }
            }
            .listStyle(.insetGrouped)
            .background(Theme.cyberBackground)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
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
        .onAppear {
            calculateCacheSize()
        }
        .preferredColorScheme(.dark)
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
