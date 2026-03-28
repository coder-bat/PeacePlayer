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
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    
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
                        .minimumScaleFactor(0.8)
                        .foregroundColor(.white)

                    Text(playerState.currentItem?.track.displayArtist ?? "")
                        .font(.system(size: 13))
                        .foregroundColor(.cyberDim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Controls
            HStack(spacing: 12) {
                // Play/Pause button with loading state
                ZStack {
                    Button(action: {
                        HapticManager.light()
                        playerState.togglePlayPause()
                    }) {
                        Image(systemName: playerState.playbackState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.cyberCyan)
                            .frame(width: 44, height: 44)
                    }
                    .opacity(playerState.playbackState.isLoading ? 0 : 1)
                    .accessibilityLabel(playerState.playbackState.isPlaying
                        ? "Pause \(playerState.currentItem?.track.title ?? "")"
                        : "Play \(playerState.currentItem?.track.title ?? "")")

                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .frame(width: 44, height: 44)
                        .opacity(playerState.playbackState.isLoading ? 1 : 0)
                }
                .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: playerState.playbackState.isLoading)

                Button(action: {
                    HapticManager.light()
                    playerState.nextTrack(userSkipped: true)
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next track")
                .disabled(!playerState.hasNextTrack)
                .opacity(playerState.hasNextTrack ? 1 : 0.25)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.cyberSurface.opacity(0.7)
            }
        )
        .overlay(alignment: .top) {
            // Playback progress bar
            GeometryReader { geo in
                let progress = playerState.duration > 0
                    ? CGFloat(playerState.currentTime / playerState.duration)
                    : 0
                Color.cyberCyan
                    .frame(width: geo.size.width * progress, height: 2)
            }
            .frame(height: 2)
        }
        .overlay(alignment: .top) {
            Color.cyberCyan.opacity(0.15).frame(height: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.cyberCyan.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 12)
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
                        withAnimation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.8)) {
                            if horizontalTranslation < -80 || horizontalVelocity < -300 {
                                // Swipe left - next track
                                HapticManager.medium()
                                playerState.nextTrack(userSkipped: true)
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
                .fill(Theme.tertiaryText.opacity(0.2))
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(Theme.tertiaryText)
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
                    CyberPlayingBars()
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

// MARK: - Cyber Playing Bars (shared across the app)
struct CyberPlayingBars: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.cyberCyan)
                    .frame(width: 3, height: animate ? 16 : 4)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear {
            animate = true
        }
    }
}

struct MiniPlayer_Previews: PreviewProvider {
    static var previews: some View {
        MiniPlayer(onExpand: {})
    }
}
