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
        .task {
            tracks = DataManager.shared.recentlyPlayed.map { $0.toTrack }
        }
    }
}

struct DiscoverRecentlyPlayedCard: View {
    let track: Track
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        Button(action: {
            playTrack()
        }) {
            VStack(alignment: .leading, spacing: 8) {
                // Artwork
                ZStack {
                    ArtworkThumbnail(url: track.artworkURL)
                        .frame(width: 140, height: 140)
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
                .frame(width: 140, alignment: .leading)
            }
        }
        .buttonStyle(.pressable)
    }

    private func playTrack() {
        // Get all recently played tracks
        let allRecentlyPlayed = DataManager.shared.recentlyPlayed.map { $0.toTrack }
        guard let tappedIndex = allRecentlyPlayed.firstIndex(where: { $0.videoId == track.videoId }) else {
            // Fallback: just play the single track
            playSingleTrack(track)
            return
        }

        print("🎵 Loading recently played queue with \(allRecentlyPlayed.count) tracks, starting from index \(tappedIndex)")

        // Build queue starting from tapped track, then the rest before it
        var queueTracks: [Track] = []
        // Add tapped track and all after it
        queueTracks.append(contentsOf: allRecentlyPlayed[tappedIndex...])
        // Add tracks before tapped track (so they're played last)
        if tappedIndex > 0 {
            queueTracks.append(contentsOf: allRecentlyPlayed[0..<tappedIndex])
        }

        // Fetch stream URLs and load queue
        var streamInfos: [(track: Track, streamUrl: String)] = []
        let group = DispatchGroup()

        for queueTrack in queueTracks {
            group.enter()
            APIService.shared.getStreamUrl(videoId: queueTrack.videoId)
                .sink(
                    receiveCompletion: { _ in group.leave() },
                    receiveValue: { streamInfo in
                        streamInfos.append((queueTrack, streamInfo.streamUrl))
                    }
                )
                .store(in: &cancellables)
        }

        group.notify(queue: .main) {
            // PlayerState is a singleton, safe to access directly
            let playerState = PlayerState.shared

            // Sort streamInfos to match queueTracks order
            let orderedStreamInfos = queueTracks.compactMap { track in
                streamInfos.first { $0.track.videoId == track.videoId }
            }

            // Clear existing queue
            playerState.clearQueue()

            // Add all tracks to queue
            for info in orderedStreamInfos {
                let item = QueueItem(
                    track: info.track,
                    streamUrl: info.streamUrl,
                    source: .stream
                )
                playerState.addToQueue(item)
            }

            // Play the first track (which is the tapped track)
            if !playerState.queue.isEmpty {
                playerState.playQueue(at: 0)
                print("✅ Started playing recently played queue with \(playerState.queue.count) tracks")
            }
        }
    }

    private func playSingleTrack(_ track: Track) {
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
            .store(in: &cancellables)
    }
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
        .task {
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
                        .minimumScaleFactor(0.8)
                    
                    Text(track.displayArtist)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
            .store(in: &cancellables)
    }
}
