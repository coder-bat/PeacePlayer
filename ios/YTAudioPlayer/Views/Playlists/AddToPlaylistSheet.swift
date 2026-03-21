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
    
    var body: some View {
        NavigationView {
            List {
                // Track info header
                Section {
                    HStack(spacing: 12) {
                        ArtworkThumbnail(url: track.artworkURL)
                            .frame(width: 60, height: 60)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.headline)
                                .lineLimit(1)
                            
                            Text(track.displayArtist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // Create new playlist
                Section {
                    if isCreatingNew {
                        HStack {
                            TextField("Playlist Name", text: $newPlaylistName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            
                            Button("Create") {
                                createPlaylist()
                            }
                            .disabled(newPlaylistName.isEmpty)
                            
                            Button("Cancel") {
                                isCreatingNew = false
                                newPlaylistName = ""
                            }
                            .foregroundColor(.secondary)
                        }
                    } else {
                        Button {
                            isCreatingNew = true
                        } label: {
                            Label("New Playlist", systemImage: "plus.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                
                // Recently modified playlists
                if !recentlyModified.isEmpty && !isCreatingNew {
                    Section("Recently Modified") {
                        ForEach(recentlyModified) { playlist in
                            PlaylistRow(
                                playlist: playlist,
                                track: track,
                                isAdded: playlistManager.isTrackInPlaylist(track.videoId, playlistId: playlist.id)
                            ) {
                                toggleTrackInPlaylist(playlist.id)
                            }
                        }
                    }
                }
                
                // All playlists
                if !userPlaylists.isEmpty && !isCreatingNew {
                    Section("All Playlists") {
                        ForEach(userPlaylists) { playlist in
                            PlaylistRow(
                                playlist: playlist,
                                track: track,
                                isAdded: playlistManager.isTrackInPlaylist(track.videoId, playlistId: playlist.id)
                            ) {
                                toggleTrackInPlaylist(playlist.id)
                            }
                        }
                    }
                }
                
                // Empty state
                if userPlaylists.isEmpty && !isCreatingNew {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            
                            Text("No Playlists Yet")
                                .font(.headline)
                            
                            Text("Create a playlist to add this track")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
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
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                // Playlist artwork placeholder
                PlaylistArtworkMini(trackIds: Array(playlist.trackIds.prefix(4)))
                    .frame(width: 50, height: 50)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.body.bold())
                        .foregroundColor(.primary)
                    
                    Text("\(playlist.trackCount) songs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.title3)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
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
                .fill(Color.gray.opacity(0.2))
            
            if trackIds.isEmpty {
                Image(systemName: "music.note")
                    .foregroundColor(.gray)
            } else if trackIds.count == 1 {
                // Single track - show music note with placeholder
                Image(systemName: "music.note")
                    .foregroundColor(.gray)
            } else {
                // Multiple tracks - show grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 2) {
                    ForEach(0..<min(4, trackIds.count), id: \.self) { _ in
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
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
