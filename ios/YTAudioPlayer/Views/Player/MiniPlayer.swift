//
//  MiniPlayer.swift
//  YTAudioPlayer
//
//  Mini player with swipe gestures
//

import SwiftUI

struct MiniPlayer: View {
    @StateObject private var playerState = PlayerState.shared
    // C-2026-06-28: read currentTime / duration / progress from the
    // focused PlaybackClock instead of PlayerState. PlayerState is a
    // god object — every @Published change re-renders every observer.
    // PlaybackClock only re-renders the views that observe it.
    @StateObject private var clock = PlayerState.shared.playbackClock
    let onExpand: () -> Void

    // 2026-06-28 (S7c): compact mode is used when the mini player is
    // embedded in the bottom bar alongside the floating tab pill.
    // Drops the skip-forward button, the live/audiobook badges, the
    // standalone background, and tightens the layout so the row
    // fits inside ~50% of the screen width.
    var compact: Bool = false

    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    @GestureState private var dragState = CGSize.zero
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    
    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            // Animated artwork — smaller in compact mode so the
            // title gets more room.
            ArtworkView(
                artworkURL: playerState.currentItem?.track.artworkURL,
                isPlaying: playerState.playbackState.isPlaying,
                isLoading: playerState.playbackState.isLoading
            )
            .frame(width: compact ? 32 : 44, height: compact ? 32 : 44)
            
            // Track Info - tappable for expand
            Button(action: {
                HapticManager.medium()
                onExpand()
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(playerState.currentItem?.track.title ?? "")
                            .font(.system(size: compact ? 13 : 15, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundColor(.white)

                        if !compact && playerState.contentType == .liveRadio {
                            Text("LIVE")
                                .fixedSize()
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.cyberMagenta))
                        }

                        if !compact && playerState.contentType == .audiobook {
                            Image(systemName: "book.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.cyberCyan))
                        }
                    }

                    if playerState.contentType == .audiobook {
                        if !playerState.currentChapters.isEmpty {
                            Text("Ch. \(playerState.currentChapterIndex + 1) of \(playerState.currentChapters.count)")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.cyberDim)
                                .lineLimit(1)
                        } else {
                            Text("Loading chapters...")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.cyberDim.opacity(0.6))
                                .lineLimit(1)
                        }
                    } else {
                        Text(playerState.currentItem?.track.displayArtist ?? "")
                            .font(.system(size: compact ? 11 : 13))
                            .foregroundColor(Theme.cyberDim)
                            .lineLimit(1)
                            .minimumScaleFactor(compact ? 0.7 : 0.8)
                    }
                }
                .frame(maxWidth: compact ? .infinity : 180, alignment: .leading)
            }
            .buttonStyle(.plain)

            // 2026-06-28 (S7c): in compact mode drop the spacer +
            // next-track button so the row fits the 50% width budget.
            if compact {
                Button(action: {
                    HapticManager.light()
                    playerState.togglePlayPause()
                }) {
                    Image(systemName: playerState.playbackState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.cyberCyan)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(playerState.playbackState.isPlaying ? "Pause" : "Play")
            } else {
                Spacer()

                HStack(spacing: 12) {
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
        }
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.vertical, compact ? 6 : 10)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 44 : 64)
        .background(compact
            ? AnyView(Color.clear)
            : AnyView(Rectangle().fill(.ultraThinMaterial)))
        .overlay(alignment: .top) {
            // Playback progress bar (hidden for live radio, hidden in compact mode)
            if !compact && playerState.contentType != .liveRadio {
                GeometryReader { geo in
                    let progress = clock.duration > 0
                        ? CGFloat(clock.currentTime / clock.duration)
                        : 0
                    Color.cyberCyan
                        .frame(width: geo.size.width * progress, height: 2)
                }
                .frame(height: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 22 : 20))
        .overlay(
            Group {
                if compact {
                    Capsule().stroke(Color.cyberCyan.opacity(0.3), lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.cyberCyan.opacity(0.2), lineWidth: 1)
                }
            }
        )
        .shadow(color: compact ? .clear : Color.black.opacity(0.3), radius: 10, x: 0, y: 4)
        .padding(.horizontal, compact ? 0 : 12)
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
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.cyberCyan)
                    .frame(width: 3, height: animate ? 16 : 4)
                    .animation(
                        reduceMotion ? .none : Animation.easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear {
            if !reduceMotion {
                animate = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct MiniPlayer_Previews: PreviewProvider {
    static var previews: some View {
        MiniPlayer(onExpand: {})
    }
}
