//
//  RecentlyPlayedSection.swift
//  YTAudioPlayer
//
//  Horizontal scrolling recently played tracks
//

import SwiftUI
import Combine

struct RecentlyPlayedSection: View {
    @State private var tracks: [Track] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Recently Played")
                    .font(.title2.bold())
                
                Spacer()
                
                if !tracks.isEmpty {
                    NavigationLink("See All") {
                        RecentlyPlayedListView()
                    }
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)
            
            // Horizontal Scroll
            if tracks.isEmpty {
                // Empty state
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("Start listening to see your history")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 120)
                    Spacer()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(tracks.prefix(10)) { track in
                            DiscoverRecentlyPlayedCard(track: track)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .onAppear {
            tracks = DataManager.shared.recentlyPlayed.map { $0.toTrack }
        }
    }
}

struct DiscoverRecentlyPlayedCard: View {
    let track: Track
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            playTrack()
        }) {
            VStack(alignment: .leading, spacing: 8) {
                // Artwork
                ZStack {
                    ArtworkThumbnail(url: track.artworkURL)
                        .frame(width: 140, height: 140)
                    
                    // Play overlay
                    if isPressed {
                        Color.black.opacity(0.3)
                        Image(systemName: "play.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                    }
                }
                .cornerRadius(8)
                
                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    
                    Text(track.displayArtist)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 140, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.95 : 1)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
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

struct RecentlyPlayedListView: View {
    @State private var tracks: [Track] = []
    
    var body: some View {
        List {
            ForEach(tracks) { track in
                SimpleTrackRow(track: track)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Recently Played")
        .onAppear {
            tracks = DataManager.shared.recentlyPlayed.map { $0.toTrack }
        }
    }
}
//
//  SimpleTrackRow.swift
//  YTAudioPlayer
//
//  Simple track row for lists in Discover
//

import SwiftUI
import Combine

struct SimpleTrackRow: View {
    let track: Track
    @State private var isHovered = false
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        Button(action: {
            playTrack()
        }) {
            HStack(spacing: 12) {
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
}
