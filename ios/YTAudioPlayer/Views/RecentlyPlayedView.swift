//
//  RecentlyPlayedView.swift
//  YTAudioPlayer
//
//  Shows recently played tracks from DataManager
//

import SwiftUI
import Combine

struct RecentlyPlayedView: View {
    @StateObject private var dataManager = DataManager.shared
    @StateObject private var playerState = PlayerState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        NavigationView {
            List {
                ForEach(dataManager.recentlyPlayed) { track in
                    RecentlyPlayedRow(
                        track: track,
                        isPlaying: playerState.currentItem?.track.videoId == track.videoId
                    ) {
                        playTrack(track)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Recently Played")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func playTrack(_ track: RecentTrack) {
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .handleErrors(with: .shared)
            .sink(receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track.toTrack,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                playerState.play(item: item)
            })
            .store(in: &cancellables)
    }
}

struct RecentlyPlayedRow: View {
    let track: RecentTrack
    let isPlaying: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ArtworkThumbnail(url: track.artworkURL)
                    .frame(width: 50, height: 50)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 16, weight: isPlaying ? .bold : .semibold))
                        .foregroundColor(isPlaying ? .accentColor : .primary)
                        .lineLimit(1)
                    
                    Text(track.displayArtist)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    if track.playbackProgress > 0 && track.playbackProgress < 1 {
                        Text("\(Int(track.playbackProgress * 100))% played")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isPlaying {
                    PlayingBars()
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct RecentlyPlayedView_Previews: PreviewProvider {
    static var previews: some View {
        RecentlyPlayedView()
    }
}
