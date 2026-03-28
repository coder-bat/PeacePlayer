//
//  CreatePlaylistSheet.swift
//  YTAudioPlayer
//
//  Sheet for creating new playlists with options
//

import SwiftUI

struct CreatePlaylistSheet: View {
    enum Field { case name, description }
    @StateObject private var playlistManager = PlaylistManager.shared
    @State private var name = ""
    @State private var description = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    
    var body: some View {
        NavigationView {
            ZStack {
                Theme.cyberBackground.ignoresSafeArea()

                List {
                    Section {
                        TextField("Playlist Name", text: $name)
                            .foregroundColor(.white)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .autocorrectionDisabled()
                            .onSubmit { focusedField = .description }
                        TextField("Description (optional)", text: $description)
                            .foregroundColor(.white)
                            .focused($focusedField, equals: .description)
                            .submitLabel(.done)
                            .autocorrectionDisabled()
                            .onSubmit { createPlaylist() }
                    }
                    .listRowBackground(Color.cyberSurface)

                    Section {
                        Button {
                            createPlaylist()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Create Playlist")
                                    .font(.headline)
                                    .foregroundColor(name.isEmpty ? .cyberDim : .cyberCyan)
                                Spacer()
                            }
                        }
                        .disabled(name.isEmpty)
                        .listRowBackground(Color.cyberSurface)
                    }
                }
                .listStyle(.insetGrouped)
                .onAppear { UITableView.appearance().backgroundColor = .clear }
                .onDisappear { UITableView.appearance().backgroundColor = .systemGroupedBackground }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.cyberDim)
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
