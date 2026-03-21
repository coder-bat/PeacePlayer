//
//  TrendingSection.swift
//  YTAudioPlayer
//
//  Trending tracks section
//

import SwiftUI
import Combine

struct TrendingSection: View {
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var showGenrePicker = false
    
    @AppStorage("trendingGenre") private var selectedGenre: String = ""
    
    let genres = ["Pop", "Hip Hop", "Rock", "Electronic", "R&B", "Country", "Jazz", "Classical", "Latin", "K-Pop"]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Trending")
                    .font(.title2.bold())
                
                Spacer()
                
                if !tracks.isEmpty {
                    Button(action: {
                        refreshTrending()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .padding(.horizontal)
            
            // Content
            if selectedGenre.isEmpty {
                // Show genre picker
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor)
                    
                    Text("Choose Your Genre")
                        .font(.headline)
                    
                    Text("Select a genre to see trending music")
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
                        title: "Trending Genre"
                    )
                }
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if tracks.isEmpty {
                // Fallback content
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<3) { index in
                        TrendingRowPlaceholder(rank: index + 1)
                    }
                }
                .padding(.horizontal)
            } else {
                VStack(alignment: .leading, spacing: 0) {
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
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    
                    ForEach(Array(tracks.prefix(5).enumerated()), id: \.element.id) { index, track in
                        TrendingRow(track: track, rank: index + 1)
                    }
                }
                .padding(.horizontal)
                .sheet(isPresented: $showGenrePicker) {
                    GenrePickerSheet(
                        genres: genres,
                        selectedGenre: $selectedGenre,
                        title: "Trending Genre"
                    )
                }
            }
        }
        .onAppear {
            loadTrending()
        }
        .onChange(of: selectedGenre) { _ in
            loadTrending()
        }
    }
    
    private func loadTrending() {
        isLoading = true

        // Use charts endpoint for real trending data
        APIService.shared.fetchTrending()
            .sink(receiveCompletion: { _ in
                isLoading = false
            }, receiveValue: { fetchedTracks in
                tracks = fetchedTracks
            })
            .store(in: &cancellables)
    }
    
    private func refreshTrending() {
        loadTrending()
    }
    
    @State private var cancellables = Set<AnyCancellable>()
}

struct TrendingRow: View {
    let track: Track
    let rank: Int
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            playTrack()
        }) {
            HStack(spacing: 16) {
                // Rank
                Text("\(rank)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 24, alignment: .center)
                
                // Artwork
                ArtworkThumbnail(url: track.artworkURL)
                    .frame(width: 50, height: 50)
                
                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    
                    Text(track.displayArtist)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Play button
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.vertical, 8)
            .background(isHovered ? Color(.systemGray6) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hover
            }
        }
    }
    
    private func playTrack() {
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .sink(receiveCompletion: { _ in }, receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                PlayerState.shared.play(item: item)
            })
            .store(in: &cancellables)
    }
    
    @State private var cancellables = Set<AnyCancellable>()
}

struct TrendingRowPlaceholder: View {
    let rank: Int
    
    var body: some View {
        HStack(spacing: 16) {
            Text("\(rank)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .center)
            
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 50, height: 50)
            
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 150, height: 16)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 100, height: 14)
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
