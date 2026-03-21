//
//  MiniPlayer.swift
//  YTAudioPlayer
//
//  Mini player with swipe gestures
//

import SwiftUI

struct MiniPlayer: View {
    @StateObject private var playerState = PlayerState.shared
    let onExpand: () -> Void
    
    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    @GestureState private var dragState = CGSize.zero
    
    var body: some View {
        HStack(spacing: 12) {
            // Animated artwork
            ArtworkView(
                artworkURL: playerState.currentItem?.track.artworkURL,
                isPlaying: playerState.playbackState.isPlaying,
                isLoading: playerState.playbackState.isLoading
            )
            .frame(width: 44, height: 44)
            
            // Track Info - tappable for expand
            Button(action: {
                HapticManager.medium()
                onExpand()
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playerState.currentItem?.track.title ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    Text(playerState.currentItem?.track.displayArtist ?? "")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Controls
            HStack(spacing: 12) {
                // Play/Pause button with loading state
                ZStack {
                    if playerState.playbackState.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(width: 44, height: 44)
                    } else {
                        Button(action: { 
                            HapticManager.light()
                            playerState.togglePlayPause() 
                        }) {
                            Image(systemName: playerState.playbackState.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.accentColor)
                                .frame(width: 44, height: 44)
                        }
                    }
                }
                
                Button(action: { 
                    HapticManager.light()
                    playerState.nextTrack() 
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                }
                .disabled(!playerState.hasNextTrack)
                .opacity(playerState.hasNextTrack ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: -1)
        // Swipe gestures
        .offset(x: offset)
        .gesture(
            DragGesture()
                .updating($dragState) { value, state, _ in
                    state = value.translation
                }
                .onChanged { value in
                    isDragging = true
                    let horizontalTranslation = value.translation.width
                    let verticalTranslation = value.translation.height
                    
                    // Determine primary direction
                    if abs(horizontalTranslation) > abs(verticalTranslation) {
                        // Horizontal swipe - for track skipping
                        // Apply resistance
                        if horizontalTranslation > 0 {
                            // Swiping right (previous) - resist
                            offset = horizontalTranslation * 0.3
                        } else {
                            // Swiping left (next) - resist
                            offset = horizontalTranslation * 0.3
                        }
                    } else {
                        // Vertical swipe - track for expand/dismiss
                        // No visual offset needed, just track the gesture
                    }
                }
                .onEnded { value in
                    isDragging = false
                    let horizontalTranslation = value.translation.width
                    let verticalTranslation = value.translation.height
                    let horizontalVelocity = value.predictedEndLocation.x - value.location.x
                    
                    // Determine primary direction
                    if abs(horizontalTranslation) > abs(verticalTranslation) {
                        // Horizontal swipe - handle track skipping
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if horizontalTranslation < -80 || horizontalVelocity < -300 {
                                // Swipe left - next track
                                HapticManager.medium()
                                playerState.nextTrack()
                                offset = 0
                            } else if horizontalTranslation > 80 || horizontalVelocity > 300 {
                                // Swipe right - previous track
                                HapticManager.medium()
                                playerState.previousTrack()
                                offset = 0
                            } else {
                                // Snap back
                                offset = 0
                            }
                        }
                    } else {
                        // Vertical swipe - handle expand
                        if verticalTranslation < -100 {
                            // Swipe up - expand to full player
                            HapticManager.medium()
                            onExpand()
                        }
                        // Swipe down on mini player does nothing (it's already mini)
                    }
                }
        )
        // Tap to expand (but not when dragging)
        .onTapGesture {
            if !isDragging {
                HapticManager.medium()
                onExpand()
            }
        }
    }
}

// MARK: - Animated Artwork
struct ArtworkView: View {
    let artworkURL: URL?
    let isPlaying: Bool
    var isLoading: Bool = false
    @State private var isLoaded = false
    
    var body: some View {
        ZStack {
            // Placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.gray)
                )
            
            // Loaded image with fade using cache
            if let url = artworkURL {
                CachedAsyncImage(url: url) {
                    EmptyView()
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipped()
                .opacity(isLoaded ? 1 : 0)
                .onAppear {
                    withAnimation(.easeIn(duration: 0.3)) {
                        isLoaded = true
                    }
                }
            }
            
            // Loading overlay
            if isLoading {
                Color.black.opacity(0.4)
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.6)
            }
        }
        .cornerRadius(8)
        .overlay(
            // Playing indicator (only when not loading)
            Group {
                if isPlaying && !isLoading {
                    PlayingBars()
                        .frame(width: 16, height: 16)
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(2)
        )
    }
}

// MARK: - Playing Bars Animation
struct PlayingBars: View {
    @State private var animating = false
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: animating ? CGFloat.random(in: 4...12) : 4)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.1),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
        }
    }
}

struct MiniPlayer_Previews: PreviewProvider {
    static var previews: some View {
        MiniPlayer(onExpand: {})
    }
}
