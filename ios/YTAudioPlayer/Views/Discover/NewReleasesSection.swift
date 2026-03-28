//
//  NewReleasesSection.swift
//  YTAudioPlayer
//
//  New music releases section
//

import SwiftUI
import Combine

struct NewReleasesSection: View {
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var showGenrePicker = false
    
    @AppStorage("newReleasesGenre") private var selectedGenre: String = ""
    
    let genres = ["Pop", "Hip Hop", "Rock", "Electronic", "R&B", "Country", "Jazz", "Classical", "Latin", "K-Pop"]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("New Releases")
                    .font(.title2.bold())
                
                Spacer()
                
                if !tracks.isEmpty {
                    NavigationLink("See All") {
                        NewReleasesListView(tracks: tracks)
                    }
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)
            
            // Content
            if selectedGenre.isEmpty {
                // Show genre picker
                VStack(spacing: 16) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor)
                    
                    Text("Choose Your Genre")
                        .font(.headline)
                    
                    Text("Select a genre to see new releases")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        showGenrePicker = true
                    }) {
                        Text("Select Genre")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.accentColor)
                            .cornerRadius(20)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .sheet(isPresented: $showGenrePicker) {
                    GenrePickerSheet(
                        genres: genres,
                        selectedGenre: $selectedGenre,
                        title: "New Releases Genre"
                    )
                }
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Show selected genre with change option
                    HStack {
                        Text(selectedGenre)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .cornerRadius(12)
                        
                        Button(action: {
                            showGenrePicker = true
                        }) {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if !tracks.isEmpty {
                            NavigationLink("See All") {
                                NewReleasesListView(tracks: tracks)
                            }
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(tracks.prefix(8)) { track in
                                NewReleaseCard(track: track)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .sheet(isPresented: $showGenrePicker) {
                    GenrePickerSheet(
                        genres: genres,
                        selectedGenre: $selectedGenre,
                        title: "New Releases Genre"
                    )
                }
            }
        }
        .task {
            loadNewReleases()
        }
        .onChange(of: selectedGenre) { _ in
            loadNewReleases()
        }
    }
    
    private func loadNewReleases() {
        isLoading = true

        // Use new releases endpoint for real data
        APIService.shared.fetchNewReleases()
            .sink(receiveCompletion: { _ in
                isLoading = false
            }, receiveValue: { fetchedTracks in
                tracks = fetchedTracks
            })
            .store(in: &cancellableHolder.cancellables)
    }
    
    private class CancellableHolder: ObservableObject {
        var cancellables = Set<AnyCancellable>()
    }
    @StateObject private var cancellableHolder = CancellableHolder()
}

struct NewReleaseCard: View {
    let track: Track
    
    var body: some View {
        Button(action: {
            playTrack()
        }) {
            VStack(alignment: .leading, spacing: 8) {
                // Artwork with "New" badge
                ZStack(alignment: .topLeading) {
                    ArtworkThumbnail(url: track.artworkURL)
                        .frame(width: 150, height: 150)
                    
                    // New badge
                    Text("NEW")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.cyberMagenta)
                        .cornerRadius(4)
                        .padding(8)
                }
                .cornerRadius(8)
                
                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    
                    Text(track.displayArtist)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: 150, alignment: .leading)
            }
        }
        .buttonStyle(.pressable)
    }
    
    private func playTrack() {
        HapticManager.medium()
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    ErrorHandler.shared.handleAPIError(error)
                }
            }, receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                PlayerState.shared.play(item: item)
            })
            .store(in: &cancellableHolder.cancellables)
    }
    
    private class CancellableHolder: ObservableObject {
        var cancellables = Set<AnyCancellable>()
    }
    @StateObject private var cancellableHolder = CancellableHolder()
}

struct NewReleasesListView: View {
    let tracks: [Track]
    
    var body: some View {
        List {
            ForEach(tracks) { track in
                SimpleTrackRow(track: track)
            }
        }
        .listStyle(.plain)
        .navigationTitle("New Releases")
    }
}
