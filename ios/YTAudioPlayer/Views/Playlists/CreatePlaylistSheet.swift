//
//  CreatePlaylistSheet.swift
//  YTAudioPlayer
//
//  Sheet for creating new playlists with options
//

import SwiftUI

struct CreatePlaylistSheet: View {
    @StateObject private var playlistManager = PlaylistManager.shared
    @State private var name = ""
    @State private var description = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Playlist Name", text: $name)
                    TextField("Description (Optional)", text: $description)
                }
                
                Section {
                    Button {
                        createPlaylist()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Create Playlist")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(name.isEmpty)
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func createPlaylist() {
        guard !name.isEmpty else { return }
        
        let playlist = playlistManager.createPlaylist(
            name: name,
            description: description.isEmpty ? nil : description
        )
        
        HapticManager.success()
        dismiss()
    }
}
