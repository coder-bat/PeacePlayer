//
//  AddToPlaylistSheet.swift
//  YTAudioPlayer
//
//  Sheet for adding tracks to playlists
//

import SwiftUI

struct AddToPlaylistSheet: View {
    let track: Track
    @StateObject private var playlistManager = PlaylistManager.shared
    @State private var newPlaylistName = ""
    @State private var isCreatingNew = false
    @Environment(\.dismiss) private var dismiss
    
    private var userPlaylists: [Playlist] {
        playlistManager.playlists.filter { !$0.isSmart }
    }
    
    private var recentlyModified: [Playlist] {
        playlistManager.recentlyModifiedPlaylists(limit: 3)
    }
    
    // Deck design system (docs/design/deck-design-system.md §8). Drawn
    // on the Deck when the turntable flag is on; the old drawing stays
    // as `legacyBody` until the flag retires.
    @ObservedObject private var featureFlags = FeatureFlags.shared
    @FocusState private var nameFocused: Bool
    private var deck: Bool { featureFlags.turntableHome }

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: a walnut board with the name and Done, the track being
    /// added on the wall, then the playlists as rows on ledges. A lamp
    /// is lit on every playlist the track is already in.
    private var deckBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Add to playlist")
                    .font(DeckType.screenTitle)
                    .foregroundColor(TurntableTokens.cream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                DeckButton(title: "Done", kind: .card) { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .deckPlinth(cornerRadius: 0)

            ScrollView {
                VStack(spacing: 0) {
                    DeckTrackRow(
                        title: track.title,
                        subtitle: track.displayArtist,
                        artworkURL: track.artworkURL,
                        smallPrint: DeckFormat.runtime(track.durationSeconds)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    deckNewPlaylist
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)

                    if !isCreatingNew {
                        if userPlaylists.isEmpty {
                            VStack(spacing: 8) {
                                Text("No playlists yet")
                                    .font(DeckType.title)
                                    .foregroundColor(TurntableTokens.cream)
                                Text("Make one to put this song in.")
                                    .font(DeckType.subtitle)
                                    .foregroundColor(TurntableTokens.cream.opacity(0.55))
                            }
                            .padding(.vertical, 24)
                        } else {
                            if !recentlyModified.isEmpty {
                                deckSection("Recently modified", recentlyModified)
                            }
                            deckSection("All playlists", userPlaylists)
                        }
                    }
                    Color.clear.frame(height: 40)
                }
            }
        }
        .background(DeckRoom())
        .environment(\.deckStyle, true)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var deckNewPlaylist: some View {
        if isCreatingNew {
            VStack(spacing: 12) {
                TextField("", text: $newPlaylistName, prompt: Text("Playlist name").foregroundColor(TurntableTokens.cream.opacity(0.4)))
                    .font(DeckType.body)
                    .foregroundColor(TurntableTokens.cream)
                    .tint(DeckSignal.live)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .onSubmit { createPlaylist() }
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .deckWell(Capsule(), lit: nameFocused ? DeckSignal.live : nil)

                HStack(spacing: 12) {
                    DeckButton(title: "Cancel", fillsWidth: true) {
                        isCreatingNew = false
                        newPlaylistName = ""
                    }
                    DeckButton(title: "Create", kind: .card, fillsWidth: true) {
                        createPlaylist()
                    }
                    .opacity(newPlaylistName.isEmpty ? 0.45 : 1)
                    .disabled(newPlaylistName.isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        } else {
            DeckButton(title: "New playlist", symbol: "plus", fillsWidth: true) {
                HapticManager.light()
                isCreatingNew = true
            }
        }
    }

    private func deckSection(_ title: String, _ playlists: [Playlist]) -> some View {
        VStack(spacing: 0) {
            DeckLedge(title: title, count: playlists.count)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            ForEach(playlists) { playlist in
                PlaylistRow(
                    playlist: playlist,
                    track: track,
                    isAdded: playlistManager.isTrackInPlaylist(track.videoId, playlistId: playlist.id)
                ) {
                    toggleTrackInPlaylist(playlist.id)
                }
                .padding(.horizontal, 16)
            }
            Color.clear.frame(height: 14)
        }
    }

    private var legacyBody: some View {
        NavigationStack {
            ZStack {
                Theme.cyberBackground.ignoresSafeArea()

                List {
                    // Track info header
                    Section {
                        HStack(spacing: 12) {
                            ArtworkThumbnail(url: track.artworkURL)
                                .frame(width: 60, height: 60)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)

                                Text(track.displayArtist)
                                    .font(.subheadline)
                                    .foregroundColor(.cyberDim)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.cyberSurface)
                    }

                    // Create new playlist
                    Section {
                        if isCreatingNew {
                            HStack {
                                TextField("Playlist Name", text: $newPlaylistName)
                                    .textFieldStyle(.neon)
                                    .submitLabel(.done)
                                    .autocorrectionDisabled()
                                    .onSubmit { createPlaylist() }

                                Button("Create") {
                                    createPlaylist()
                                }
                                .foregroundColor(.cyberCyan)
                                .disabled(newPlaylistName.isEmpty)

                                Button("Cancel") {
                                    isCreatingNew = false
                                    newPlaylistName = ""
                                }
                                .foregroundColor(.cyberDim)
                            }
                        } else {
                            Button {
                                isCreatingNew = true
                            } label: {
                                Label("New Playlist", systemImage: "plus.circle.fill")
                                    .foregroundColor(.cyberCyan)
                            }
                        }
                    }
                    .listRowBackground(Color.cyberSurface)

                    // Recently modified playlists
                    if !recentlyModified.isEmpty && !isCreatingNew {
                        Section(header:
                            Text("RECENTLY MODIFIED")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                        ) {
                            ForEach(recentlyModified) { playlist in
                                PlaylistRow(
                                    playlist: playlist,
                                    track: track,
                                    isAdded: playlistManager.isTrackInPlaylist(track.videoId, playlistId: playlist.id)
                                ) {
                                    toggleTrackInPlaylist(playlist.id)
                                }
                                .listRowBackground(Color.cyberSurface)
                            }
                        }
                    }

                    // All playlists
                    if !userPlaylists.isEmpty && !isCreatingNew {
                        Section(header:
                            Text("ALL PLAYLISTS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                        ) {
                            ForEach(userPlaylists) { playlist in
                                PlaylistRow(
                                    playlist: playlist,
                                    track: track,
                                    isAdded: playlistManager.isTrackInPlaylist(track.videoId, playlistId: playlist.id)
                                ) {
                                    toggleTrackInPlaylist(playlist.id)
                                }
                                .listRowBackground(Color.cyberSurface)
                            }
                        }
                    }

                    // Empty state
                    if userPlaylists.isEmpty && !isCreatingNew {
                        Section {
                            VStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 40))
                                    .foregroundColor(.cyberDim)

                                Text("No Playlists Yet")
                                    .font(.headline)
                                    .foregroundColor(.white)

                                Text("Create a playlist to add this track")
                                    .font(.subheadline)
                                    .foregroundColor(.cyberDim)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .onAppear { UITableView.appearance().backgroundColor = .clear }
                .onDisappear { UITableView.appearance().backgroundColor = .systemGroupedBackground }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.cyberCyan)
                }
            }
        }
    }
    
    private func createPlaylist() {
        guard !newPlaylistName.isEmpty else { return }
        
        let playlist = playlistManager.createPlaylist(name: newPlaylistName)
        playlistManager.addTrack(track, to: playlist.id)
        
        HapticManager.success()
        dismiss()
    }
    
    private func toggleTrackInPlaylist(_ playlistId: UUID) {
        if playlistManager.isTrackInPlaylist(track.videoId, playlistId: playlistId) {
            playlistManager.removeTrack(track.videoId, from: playlistId)
        } else {
            playlistManager.addTrack(track, to: playlistId)
        }
        HapticManager.light()
    }
}

// MARK: - Playlist Row

struct PlaylistRow: View {
    let playlist: Playlist
    let track: Track
    let isAdded: Bool
    let onTap: () -> Void

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: a small walnut block with the playlist's symbol, the name
    /// in print, the count in small print, and a lamp that is lit when
    /// the track is already in it (cyan: "this one").
    private var deckBody: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.7))
                    .frame(width: 46, height: 46)
                    .deckPlinth(cornerRadius: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(DeckType.title)
                        .foregroundColor(TurntableTokens.cream)
                    Text(DeckFormat.tracks(playlist.trackCount))
                        .font(DeckType.subtitle)
                        .foregroundColor(TurntableTokens.cream.opacity(0.55))
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                if isAdded {
                    Text("ADDED")
                        .font(DeckType.smallPrint)
                        .foregroundColor(TurntableTokens.brass)
                }
                DeckLamp(color: DeckSignal.live, state: isAdded ? .lit : .idle, size: 6)
            }
            .frame(minHeight: 58)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(TurntableTokens.cream.opacity(0.08)).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playlist.name)
        .accessibilityValue(isAdded ? "Added" : "Not added")
        .accessibilityHint(isAdded ? "Removes the song from this playlist" : "Adds the song to this playlist")
    }

    private var legacyBody: some View {
        Button(action: onTap) {
            HStack {
                // Playlist artwork placeholder
                PlaylistArtworkMini(trackIds: Array(playlist.trackIds.prefix(4)))
                    .frame(width: 50, height: 50)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.body.bold())
                        .foregroundColor(.white)

                    Text("\(playlist.trackCount) songs")
                        .font(.caption)
                        .foregroundColor(.cyberDim)
                }

                Spacer()

                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.cyberCyan)
                        .font(.title3)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.cyberDim)
                        .font(.title3)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mini Artwork View

struct PlaylistArtworkMini: View {
    let trackIds: [String]
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.cyberDim.opacity(0.2))
            
            if trackIds.isEmpty {
                Image(systemName: "music.note")
                    .foregroundColor(.cyberDim)
            } else if trackIds.count == 1 {
                // Single track - show music note with placeholder
                Image(systemName: "music.note")
                    .foregroundColor(.cyberDim)
            } else {
                // Multiple tracks - show grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 2) {
                    ForEach(0..<min(4, trackIds.count), id: \.self) { _ in
                        Rectangle()
                            .fill(Color.cyberDim.opacity(0.3))
                    }
                }
                .padding(2)
            }
        }
        .cornerRadius(6)
    }
}

// MARK: - Preview

struct AddToPlaylistSheet_Previews: PreviewProvider {
    static var previews: some View {
        AddToPlaylistSheet(
            track: Track(
                videoId: "test",
                title: "Test Track",
                artists: ["Test Artist"],
                album: "Test Album",
                durationSeconds: 180,
                thumbnails: [],
                isExplicit: false,
                videoType: "MUSIC"
            )
        )
    }
}
