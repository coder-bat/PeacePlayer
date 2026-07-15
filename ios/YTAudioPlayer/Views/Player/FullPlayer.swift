//
//  FullPlayer.swift
//  YTAudioPlayer
//
//  Redesigned full-screen player with organized UX
//

import SwiftUI
import MediaPlayer
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreHaptics

struct FullPlayer: View {
    @StateObject private var playerState = PlayerState.shared
    // Sprint 2 / C-4 fix: the focused PlaybackClock. progressSection
    // observes this (via the helper view below) so its 0.5s re-renders
    // don't cascade into the rest of FullPlayer.
    @StateObject private var playbackClock = PlayerState.shared.playbackClock
    @StateObject private var playlistManager = PlaylistManager.shared
    @StateObject private var songMemoryManager = SongMemoryManager.shared
    @Binding var isPresented: Bool

    private func dismiss() {
        withAnimation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.85)) {
            isPresented = false
        }
    }
    
    @State private var showQueue = false
    @State private var showSleepTimer = false
    @State private var showLyrics = false
    @State private var showAirPlayPicker = false
    @State private var showAudioSettings = false
    @State private var showShareSheet = false
    @State private var showSongMemory = false
    @State private var showOrbitalMenu = false
    @State private var dominantColor: Color = .clear
    @State private var colorExtractionTask: Task<Void, Never>?
    @State private var dragOffset: CGFloat = 0
    @State private var scrollAtTop: Bool = true
    // S13: pulse animation for the Queue button when a track is added.
    // The notification observer resets `pulseAmount` to 1.15 each time
    // a new track is queued, then animates back to 1.0 over ~0.4s.
    @State private var queuePulseAmount: CGFloat = 1.0
    @State private var showScrubberThumb = false
    @State private var scrubberHideTask: Task<Void, Never>? = nil
    @State private var isTrackInfoExpanded = false
    @State private var likePulse = false
    @State private var waveformPeaks: [Float]? = nil
    @State private var showingVisualizer = false
    @State private var showTimeCapsule = false
    @State private var showTimeCapsuleVault = false
    @State private var showAntiAlgorithm = false
    @State private var showChords = false
    @State private var showGestureHints = false
    // S16: explicit user-triggered re-entry to the gesture coach.
    // showGestureHints is the auto-show-on-first-launch flag;
    // showGestureCoach is the user-tapped "?" button flag. They
    // share the same overlay; the only difference is that
    // tapping the "?" doesn't set hasSeenGestureHints.
    @State private var showGestureCoach = false
    @State private var playbackSpeed: Float = 1.0
    @State private var isPulsing = false
    @AppStorage("hasSeenGestureHints") private var hasSeenGestureHints = false
    @StateObject private var hapticEngine = HapticSymphonyEngine.shared
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    private var currentTrack: Track? {
        playerState.currentItem?.track
    }

    private var currentTrackIsLiked: Bool {
        guard let trackId = currentTrack?.videoId else { return false }
        return playlistManager.isLiked(trackId: trackId)
    }

    private var combinedTrackLabel: String {
        guard let currentTrack else { return "" }
        return "\(currentTrack.title) — \(currentTrack.displayArtist)"
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            ZStack {
                // Background
                Color.black.ignoresSafeArea()

                // Dominant color wash (animated cross-dissolve on track change)
                dominantColor
                    .opacity(0.25)
                    .ignoresSafeArea()
                    .animation(reduceMotion ? .none : .easeInOut(duration: 0.35), value: dominantColor)

                // Optional blur background from artwork
                ArtworkBackground(url: playerState.currentItem?.track.artworkURL)

                // Main content — portrait or landscape
                if isLandscape {
                    landscapeContent(geo: geo)
                } else {
                    portraitContent
                }

                // First-run gesture coach marks
                if showGestureHints {
                    GestureCoachOverlay {
                        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.3)) {
                            showGestureHints = false
                            hasSeenGestureHints = true
                        }
                    }
                }

                // S16: user-triggered gesture coach re-entry.
                // Tapping the "?" button in the more-actions grid
                // flips showGestureCoach on. The dismiss handler
                // does NOT set hasSeenGestureHints — that flag
                // only governs the auto-show-on-first-launch
                // behavior.
                if showGestureCoach {
                    GestureCoachOverlay {
                        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.3)) {
                            showGestureCoach = false
                        }
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard !isLandscape, scrollAtTop else { return }
                        // Only respond to predominantly vertical drags so
                        // horizontal seeks on the waveform bar aren't intercepted
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        let height = value.translation.height
                        if height > 0 {
                            dragOffset = height * 0.85
                        } else {
                            dragOffset = height * 0.05
                        }
                    }
                    .onEnded { value in
                        guard !isLandscape, scrollAtTop else {
                            withAnimation(reduceMotion ? .none : .spring(response: 0.35, dampingFraction: 0.75)) {
                                dragOffset = 0
                            }
                            return
                        }
                        if value.translation.height > 100 || value.predictedEndTranslation.height > 250 {
                            HapticManager.medium()
                            dismiss()
                        } else {
                            withAnimation(reduceMotion ? .none : .spring(response: 0.35, dampingFraction: 0.75)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .sheet(isPresented: $showQueue, onDismiss: { playerState.showQueue = false }) {
                if #available(iOS 16.0, *) {
                    QueueView()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                } else {
                    QueueView()
                }
            }
            .onChange(of: playerState.showQueue) { _, shouldShow in
                if shouldShow {
                    // Small delay so the full player finishes its entry animation first
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showQueue = true
                    }
                }
            }
            .sheet(isPresented: $showLyrics) {
                LyricsView()
            }
            .sheet(isPresented: $showSleepTimer) {
                SleepTimerView()
            }
            .sheet(isPresented: $showAudioSettings) {
                AudioSettingsView()
            }
            .sheet(isPresented: $showShareSheet) {
                if let track = playerState.currentItem?.track {
                    ShareSheet(track: track)
                }
            }
            .sheet(isPresented: $showSongMemory) {
                if let track = playerState.currentItem?.track {
                    SongMemorySheet(track: track)
                }
            }
            .sheet(isPresented: $showTimeCapsule) {
                if let track = playerState.currentItem?.track {
                    TimeCapsuleSheet(track: track)
                }
            }
            .sheet(isPresented: $showTimeCapsuleVault) {
                TimeCapsuleVaultView()
            }
            .sheet(isPresented: $showAntiAlgorithm) {
                AntiAlgorithmView()
            }
            .sheet(isPresented: $showChords) {
                ChordsView()
            }
            .offset(y: dragOffset)
            .onAppear {
                extractDominantColor()
                if !hasSeenGestureHints {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        showGestureHints = true
                    }
                }
            }
            .onDisappear {
                scrubberHideTask?.cancel()
                scrubberHideTask = nil
                colorExtractionTask?.cancel()
                colorExtractionTask = nil
            }
            .onChange(of: playerState.currentItem?.track.videoId) { _, _ in
                extractDominantColor()
                isTrackInfoExpanded = false
            }
            .overlay {
                OrbitalMenu(
                    isPresented: $showOrbitalMenu,
                    onSelectTab: { tag in
                        showOrbitalMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            dismiss()
                            NotificationCenter.default.post(name: .switchTab, object: tag)
                        }
                    },
                    onDismiss: {
                        showOrbitalMenu = false
                    }
                )
                .opacity(showOrbitalMenu ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showOrbitalMenu)
            }
        }
    }

    // MARK: - Portrait Layout
    private var portraitContent: some View {
        // 2026-06-28 (S7): even vertical distribution. Replace the
        // ScrollView with a fixed VStack + Spacers so the full screen
        // is covered evenly (artwork, track info, scrubber,
        // playback controls, volume, more actions) instead of
        // everything bunched at the top.
        VStack(spacing: 0) {
            topBar

            VStack(spacing: 0) {
                Spacer(minLength: 8)
                artworkSection
                    .layoutPriority(1)
                Spacer(minLength: 16)

                trackInfoSection
                Spacer(minLength: 16)

                // 2026-06-28 (S7b): progressSection is rendered inside
                // playbackControlsSection already, so we don't add it
                // here — that would produce a second progress bar.
                playbackControlsSection
                Spacer(minLength: 16)

                VolumeSlider()
                    .padding(.horizontal, 8)
                Spacer(minLength: 16)

                moreActionsRow
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Landscape Layout
    @ViewBuilder
    private func landscapeContent(geo: GeometryProxy) -> some View {
        let artworkSize = min(geo.size.height - 80, geo.size.width * 0.4 - 32)

        HStack(spacing: 0) {
            // Left column: dismiss button + centered artwork
            VStack(spacing: 0) {
                Button(action: dismiss) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(20)
                }
                .accessibilityLabel("Dismiss player")
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                ZStack {
                    ArtworkImage(
                        url: playerState.currentItem?.track.artworkURL,
                        size: artworkSize
                    )
                    if playerState.playbackState.isLoading {
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(Color.black.opacity(0.5))
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            Text("Warming track...")
                                .font(.subheadline)
                                .foregroundColor(.white)
                        }
                    }
                }
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .stroke(currentTrackIsLiked ? Theme.cyberMagenta.opacity(0.55) : Color.clear, lineWidth: currentTrackIsLiked ? 1.5 : 0)
                )
                .shadow(
                    color: currentTrackIsLiked ? Theme.cyberMagenta.opacity(likePulse ? 0.45 : 0.22) : .black.opacity(0.3),
                    radius: currentTrackIsLiked ? (likePulse ? 26 : 18) : 20,
                    x: 0,
                    y: 10
                )
                .scaleEffect((playerState.playbackState.isPlaying ? 1.0 : 0.94) * (likePulse ? 1.06 : 1.0))
                .animation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.8), value: playerState.playbackState.isPlaying)
                .animation(reduceMotion ? .none : .spring(response: 0.25, dampingFraction: 0.6), value: likePulse)
                .onTapGesture(count: 2) {
                    toggleCurrentTrackLike()
                }

                Spacer()
            }
            .frame(width: geo.size.width * 0.42)

            // Right column: all controls in a scrollable stack
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    trackInfoSection
                    playbackControlsSection
                    VolumeSlider()
                        .padding(.horizontal, 8)
                    moreActionsRow
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Dominant Color Extraction
    private func extractDominantColor() {
        colorExtractionTask?.cancel()
        colorExtractionTask = Task {
            // 300ms debounce for rapid skipping
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            
            guard let url = playerState.currentItem?.track.artworkURL else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let ciImage = CIImage(data: data) else { return }

            let extent = CIVector(cgRect: ciImage.extent)
            guard let filter = CIFilter(name: "CIAreaAverage",
                                        parameters: [kCIInputImageKey: ciImage,
                                                     kCIInputExtentKey: extent]),
                  let outputImage = filter.outputImage else { return }

            let context = CIContext()
            var bitmap = [UInt8](repeating: 0, count: 4)
            context.render(outputImage,
                           toBitmap: &bitmap,
                           rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())

            guard !Task.isCancelled else { return }
            let color = Color(
                red: Double(bitmap[0]) / 255.0,
                green: Double(bitmap[1]) / 255.0,
                blue: Double(bitmap[2]) / 255.0
            )
            await MainActor.run {
                withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.8)) {
                    dominantColor = color
                }
            }
        }
    }
    
    // MARK: - Top Bar
    private var topBar: some View {
        ZStack {
            // Centered capsule handle (visual drag indicator)
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 5)

            // Left-aligned dismiss button
            HStack {
                Button(action: dismiss) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(12)
                }
                .accessibilityLabel("Dismiss player")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
    
    // MARK: - Artwork Section (full-width cyberpunk hero banner)
    private var artworkSection: some View {
        let w = UIScreen.main.bounds.width
        let h = w * 0.68          // ~3:2 panoramic — room for album art without going too flat
        let slash: CGFloat = 40   // diagonal drop: right side is 40pt higher than left

        return ZStack {
            // Artwork layer
            ZStack {
                Color.cyberDim.opacity(0.15)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 56))
                            .foregroundColor(.cyberDim)
                    )
                CachedAsyncImage(url: playerState.currentItem?.track.artworkURL) { EmptyView() }
                    .frame(width: w, height: h)

                if playerState.playbackState.isLoading {
                    Color.black.opacity(0.5)
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("Loading...")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                }
            }

            // Visualizer layer
            ZStack {
                Color.black
                NeuralFreqVisualizer(engine: AudioVisualizerEngine.shared, style: .neural)
                    .frame(width: w, height: h)
            }
            .opacity(showingVisualizer ? 1 : 0)
        }
        .frame(width: w, height: h)
        // Diagonal clip
        .clipShape(CyberpunkHeroShape(slashDrop: slash))
        // Clean border
        .overlay(
            CyberpunkHeroShape(slashDrop: slash)
                .stroke(
                    showingVisualizer
                        ? Color.cyberCyan.opacity(0.4)
                        : (currentTrackIsLiked ? Theme.cyberMagenta.opacity(0.4) : Color.white.opacity(0.06)),
                    lineWidth: 1
                )
        )
        // Single clean shadow
        .shadow(
            color: showingVisualizer
                ? Color.cyberCyan.opacity(0.25)
                : (currentTrackIsLiked ? Theme.cyberMagenta.opacity(0.2) : Color.black.opacity(0.3)),
            radius: 12,
            x: 0, y: 4
        )
        .scaleEffect(likePulse ? 1.025 : 1.0)
        .animation(reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.75), value: showingVisualizer)
        .animation(reduceMotion ? .none : .spring(response: 0.25, dampingFraction: 0.7), value: likePulse)
        // Extend past the parent VStack's 24pt horizontal padding to go edge-to-edge
        .padding(.horizontal, -24)
        .onTapGesture(count: 2) {
            if !showingVisualizer { toggleCurrentTrackLike() }
        }
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard horizontal > vertical else { return }
                    withAnimation(reduceMotion ? .none : .spring(response: 0.5, dampingFraction: 0.75)) {
                        showingVisualizer.toggle()
                    }
                }
        )
        .onLongPressGesture(minimumDuration: 0.6) {
            HapticManager.medium()
            showOrbitalMenu = true
        }
    }
    
    // MARK: - Track Info
    private var trackInfoSection: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? .none : .spring(response: 0.28, dampingFraction: 0.82)) {
                    isTrackInfoExpanded.toggle()
                }
            } label: {
                Text(combinedTrackLabel)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(isTrackInfoExpanded ? 3 : 1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(currentTrack == nil)

            if playerState.contentType == .liveRadio {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.cyberMagenta)
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundColor(Theme.cyberMagenta)
                }
            } else if playerState.contentType == .audiobook && !playerState.currentChapters.isEmpty {
                Text("Chapter \(playerState.currentChapterIndex + 1) of \(playerState.currentChapters.count)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            }

            // Content Source Indicator
            if let contentSource = playerState.currentItem?.contentSource {
                HStack(spacing: 4) {
                    Image(systemName: contentSource.iconName)
                        .font(.system(size: 10))
                    Text(contentSource.displayName)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(contentSource.tintColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(contentSource.tintColor.opacity(0.15))
                .cornerRadius(6)
            }

            if let memory = songMemoryManager.memory(for: currentTrack) {
                Button {
                    HapticManager.light()
                    showSongMemory = true
                } label: {
                    SongMemoryBadge(text: memory.previewText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }
    
    // MARK: - Progress Section
    // Sprint 2 / C-4 fix: extracted to a dedicated view that observes
    // only `playbackClock`. Previously this was inlined as a computed
    // property and re-rendered the entire FullPlayer body every 0.5s
    // because it read playerState.currentTime / playerState.progress.
    private var progressSection: some View {
        ProgressSection(
            clock: playbackClock,
            onSeek: { [weak playerState] newProgress in
                playerState?.seek(to: newProgress)
                withAnimation(reduceMotion ? .none : .easeIn(duration: 0.15)) { showScrubberThumb = true }
                scrubberHideTask?.cancel()
                scrubberHideTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) { showScrubberThumb = false }
                    }
                }
            },
            onScrubberDragChange: { isDragging in
                withAnimation(self.reduceMotion ? .none : .easeInOut(duration: 0.15)) { self.showScrubberThumb = isDragging }
            },
            onScrubberDragEnded: {
                HapticManager.light()
                self.scrubberHideTask?.cancel()
                self.scrubberHideTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation(self.reduceMotion ? .none : .easeOut(duration: 0.2)) { self.showScrubberThumb = false }
                    }
                }
            }
        )
        .task(id: currentTrack?.videoId) {
            self.waveformPeaks = nil
            guard let videoId = self.currentTrack?.videoId else { return }
            let peaks = await WaveformService.shared.waveform(for: videoId)
            withAnimation(self.reduceMotion ? .none : .easeIn(duration: 0.3)) {
                self.waveformPeaks = peaks
            }
        }
    }

/// Sprint 2 / C-4 helper: progress + scrubber subtree. Observes only
/// PlaybackClock so the 0.5s tick re-renders THIS view, not the parent
/// FullPlayer body. This is the primary performance win from the
/// PlaybackClock extraction.
private struct ProgressSection: View {
    @ObservedObject var clock: PlaybackClock
    @State private var waveformPeaks: [Float]?
    let onSeek: (Double) -> Void
    let onScrubberDragChange: (Bool) -> Void
    let onScrubberDragEnded: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            if let peaks = waveformPeaks {
                WaveformSeekBar(
                    peaks: peaks,
                    progress: Binding(
                        get: { clock.progress },
                        set: { _ in }
                    ),
                    onSeek: onSeek,
                    onDragChange: onScrubberDragChange
                )
                .frame(height: 48)
                .transition(.opacity)
            } else {
                // Fallback flat bar while waveform loads — reads clock directly
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: CornerRadius.xxs)
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: CornerRadius.xxs)
                            .fill(Color.white)
                            .frame(width: max(0, geometry.size.width * CGFloat(clock.progress)), height: 4)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(radius: 4)
                            .offset(x: max(0, geometry.size.width * CGFloat(clock.progress)) - 7)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newProgress = min(max(0, Double(value.location.x / geometry.size.width)), 1)
                                onSeek(newProgress)
                            }
                            .onEnded { _ in
                                onScrubberDragEnded()
                            }
                    )
                }
                .frame(height: 20)
            }

            // Time labels — read clock directly so they don't trigger
            // parent re-renders either
            HStack {
                Text(formatTime(clock.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyberDim)

                Spacer()

                // S13: render "--:--" instead of "0:00" when we genuinely don't
                // know the duration yet (live radio, HLS streams, tracks
                // whose metadata hasn't resolved). `0:00` looks like a
                // bug; `--:--` reads as "we don't know".
                Text(durationLabel)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyberDim)
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // S13: when neither `expectedDuration` (backend-supplied) nor
    // `duration` (AVPlayer-resolved) has produced a value, fall back to
    // the placeholder "--:--" so the UI doesn't display a misleading
    // "0:00". Live radio content hides the scrubber entirely (see
    // the parent `progressSection`'s `contentType != .liveRadio`
    // guard) but for HLS / HTTP streams with unknown duration this
    // branch fires.
    private var durationLabel: String {
        let resolved = clock.expectedDuration > 0 ? clock.expectedDuration : clock.duration
        return resolved > 0 ? formatTime(resolved) : "--:--"
    }
}

    private var playbackControlsSection: some View {
        VStack(spacing: 8) {
            if playerState.contentType != .liveRadio {
                progressSection
            }
            primaryControlsSection
            if playerState.contentType == .podcastEpisode || playerState.contentType == .audiobook {
                Button(action: { cyclePlaybackSpeed() }) {
                    Text(playbackSpeedText)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberCyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.cyberSurface))
                }
            }
            secondaryControlsRow
                .padding(.top, 12)
        }
    }
    
    // MARK: - Primary Controls
    private var primaryControlsSection: some View {
        HStack(spacing: 34) {
            // Previous / Skip backward
            if playerState.contentType == .liveRadio {
                Spacer().frame(width: 44)
            } else if playerState.contentType == .podcastEpisode {
                Button(action: {
                    HapticManager.light()
                    playerState.skipBackward(15)
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }
                .frame(width: 44, height: 44)
            } else if playerState.contentType == .audiobook {
                let isFirstChapter = playerState.currentChapterIndex <= 0
                Button(action: {
                    HapticManager.light()
                    playerState.skipToPreviousChapter()
                }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .opacity(isFirstChapter ? 0.3 : 1.0)
                }
                .frame(width: 44, height: 44)
                .disabled(isFirstChapter)
            } else {
                PlayerControlButton(
                    icon: "backward.fill",
                    size: 28,
                    isEnabled: playerState.hasPreviousTrack,
                    action: {
                        HapticManager.medium()
                        playerState.previousTrack()
                    }
                )
            }
            
            // Play/Pause (larger) with loading state
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 72, height: 72)
                
                if playerState.playbackState.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                        .scaleEffect(1.2)
                } else {
                    Button(action: {
                        HapticManager.medium()
                        playerState.togglePlayPause()
                    }) {
                        Image(systemName: playerState.playbackState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.black)
                            .offset(x: playerState.playbackState.isPlaying ? 0 : 2)
                    }
                    .accessibilityLabel(playerState.playbackState.isPlaying
                        ? "Pause \(playerState.currentItem?.track.title ?? "")"
                        : "Play \(playerState.currentItem?.track.title ?? "")")
                    .buttonStyle(.plain)
                }
            }
            
            // Next / Skip forward
            if playerState.contentType == .liveRadio {
                Spacer().frame(width: 44)
            } else if playerState.contentType == .podcastEpisode {
                Button(action: {
                    HapticManager.light()
                    playerState.skipForward(15)
                }) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }
                .frame(width: 44, height: 44)
            } else if playerState.contentType == .audiobook {
                let isLastChapter = playerState.currentChapterIndex >= playerState.currentChapters.count - 1 || playerState.currentChapters.isEmpty
                Button(action: {
                    HapticManager.light()
                    playerState.skipToNextChapter()
                }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .opacity(isLastChapter ? 0.3 : 1.0)
                }
                .frame(width: 44, height: 44)
                .disabled(isLastChapter)
            } else {
                PlayerControlButton(
                    icon: "forward.fill",
                    size: 28,
                    isEnabled: playerState.hasNextTrack,
                    action: {
                        HapticManager.medium()
                        playerState.nextTrack(userSkipped: true)
                    }
                )
            }
        }
    }
    private func toggleCurrentTrackLike() {
        guard let trackId = currentTrack?.videoId else { return }

        HapticManager.medium()
        playlistManager.toggleLike(trackId: trackId)

        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.18)) {
            likePulse = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.22)) {
                likePulse = false
            }
        }
    }

    // MARK: - Playback Speed (Podcast)
    private var playbackSpeedText: String {
        playbackSpeed == 1.0 ? "1x" : String(format: "%.1fx", playbackSpeed)
    }

    private func cyclePlaybackSpeed() {
        let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
        if let currentIndex = speeds.firstIndex(of: playbackSpeed) {
            playbackSpeed = speeds[(currentIndex + 1) % speeds.count]
        } else {
            playbackSpeed = 1.0
        }
        playerState.setPlaybackRate(playbackSpeed)
        HapticManager.light()
    }

    // MARK: - Secondary Controls Row (Shuffle, Repeat, Queue, Sleep)
    private var secondaryControlsRow: some View {
        HStack(spacing: 0) {
            // Shuffle
            PlayerControlButton(
                icon: "shuffle",
                size: 20,
                isActive: playerState.isShuffled,
                action: {
                    HapticManager.light()
                    playerState.toggleShuffle()
                }
            )
            .frame(maxWidth: .infinity)
            
            // Repeat
            PlayerControlButton(
                icon: playerState.repeatMode.iconName,
                size: 20,
                isActive: playerState.repeatMode != .none,
                action: {
                    HapticManager.light()
                    playerState.toggleRepeat()
                }
            )
            .frame(maxWidth: .infinity)
            
            // Queue
            PlayerControlButton(
                icon: "list.bullet",
                size: 20,
                action: {
                    HapticManager.light()
                    showQueue = true
                }
            )
            .frame(maxWidth: .infinity)
            // S13: pulse on the Queue button when a track is added from
            // the Library. NotificationCenter posts `.trackAddedToQueue`
            // from LibraryView's row context menu; we observe it here
            // and animate the icon's scale 1.0 → 1.18 → 1.0.
            .scaleEffect(queuePulseAmount)
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: queuePulseAmount)
            .onReceive(NotificationCenter.default.publisher(for: .trackAddedToQueue)) { _ in
                queuePulseAmount = 1.18
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    queuePulseAmount = 1.0
                }
            }
            
            // Sleep Timer
            PlayerControlButton(
                icon: "moon.fill",
                size: 20,
                isActive: SleepTimer.shared.isActive,
                action: {
                    HapticManager.light()
                    showSleepTimer = true
                }
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(CornerRadius.md)
    }
    
    // MARK: - More Actions Row (Lyrics, Memory, Audio, Share, AirPlay)
    private var moreActionsRow: some View {
        // S16: redesign from a single unlabeled HStack of 7 icons to
        // a labeled 2-row grid. The previous layout was 7 icons of
        // 22pt with no labels in a single row — completely
        // invisible to VoiceOver before S15, and visually
        // indistinguishable to a new user. The new layout has 8
        // cells (4×2) with icon-on-top, label-on-bottom, matching
        // the iOS Music app's more-actions sheet pattern.
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                // Lyrics
                MoreActionButton(
                    icon: "text.quote",
                    title: "Lyrics",
                    action: {
                        HapticManager.light()
                        showLyrics = true
                    }
                )

                // Guitar Chords
                MoreActionButton(
                    icon: "guitars",
                    title: "Chords",
                    action: {
                        HapticManager.light()
                        showChords = true
                    }
                )

                MoreActionButton(
                    icon: songMemoryManager.hasMemory(for: playerState.currentItem?.track) ? "sparkles.rectangle.stack.fill" : "square.and.pencil",
                    title: "Memory",
                    action: {
                        HapticManager.light()
                        showSongMemory = true
                    }
                )

                // Haptic Symphony — only on devices with haptic
                // hardware. Skip the cell entirely if not supported.
                if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
                    MoreActionButton(
                        icon: hapticEngine.isActive ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle",
                        title: hapticEngine.isActive ? "Haptic On" : "Haptic",
                        action: {
                            HapticManager.light()
                            if hapticEngine.isActive {
                                hapticEngine.stop()
                            } else {
                                hapticEngine.start()
                            }
                        }
                    )
                } else {
                    // Placeholder cell so the 4-column grid stays
                    // balanced on devices without haptic hardware.
                    Color.clear.frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 0) {
                // Time Capsule — tap = bury a new capsule (default,
                // most common). Long-press surfaces a context menu
                // with "Open Vault" as the secondary action —
                // matches the new confirmation copy in
                // TimeCapsuleSheet.sealedConfirmation and gives the
                // vault a real, reachable path from the player.
                MoreActionButton(
                    icon: "hourglass",
                    title: "Capsule",
                    action: {
                        HapticManager.light()
                        showTimeCapsule = true
                    }
                )
                .contextMenu {
                    Button {
                        HapticManager.light()
                        showTimeCapsule = true
                    } label: {
                        Label("Bury New Capsule", systemImage: "hourglass.badge.plus")
                    }
                    Button {
                        HapticManager.light()
                        showTimeCapsuleVault = true
                    } label: {
                        Label("Open Vault", systemImage: "tray.full")
                    }
                }

                // Audio Settings
                MoreActionButton(
                    icon: "waveform",
                    title: "Audio",
                    action: {
                        HapticManager.light()
                        showAudioSettings = true
                    }
                )

                // Share
                MoreActionButton(
                    icon: "square.and.arrow.up",
                    title: "Share",
                    action: {
                        HapticManager.light()
                        showShareSheet = true
                    }
                )

                // Gesture Coach re-entry (S16). The first time
                // the user opens the player, the coach is shown
                // automatically. The "?" button is how they
                // re-open it after dismissing — the master plan
                // call-out for this row was "Gesture Coach: no
                // re-entry" and this fixes it.
                MoreActionButton(
                    icon: "questionmark.circle",
                    title: "Gestures",
                    action: {
                        HapticManager.light()
                        showGestureCoach = true
                    }
                )
            }

            // AirPlay sits on its own row at the bottom — it's a
            // system control (MPVolumeView family) and the AVKit
            // route-picker doesn't compose well into the 4-column
            // grid above.
            HStack {
                Spacer()
                AirPlayButton()
                    .frame(width: 44, height: 44)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Scroll Offset PreferenceKey
private struct FullPlayerScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Volume Slider
/// S3-3 fix (H-6/H-8 from gap analysis): replaced the custom SwiftUI slider
/// + undocumented `MPVolumeView.subviews.first(where:)` hack with a direct
/// `UIViewRepresentable` wrapping `MPVolumeView`. The system volume view
/// automatically reflects hardware / AirPlay / CarPlay / Control Center
/// changes; setting the slider on the embedded MPVolumeView writes through
/// to the system volume via the public API (no private subview traversal).
struct VolumeSlider: View {
    @State private var outputVolume: Double = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var volumeObserver: NSKeyValueObservation?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.tertiaryText)
                .accessibilityHidden(true)

            // Embedded MPVolumeView — the system volume control.
            // It syncs automatically with the iOS system volume, so changes
            // from hardware buttons / AirPlay / CarPlay / Control Center
            // are reflected here. Setting its value writes back to the
            // system volume via the public `MPVolumeView` API.
            SystemVolumeView()
                .frame(height: 24)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.tertiaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(CornerRadius.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume \(Int(outputVolume * 100)) percent")
        .accessibilityValue("\(Int(outputVolume * 100))%")
        .onAppear {
            // Observe system volume changes (KVO on AVAudioSession)
            // so accessibility / on-screen indicator stays in sync when
            // the user changes volume via hardware buttons or Control
            // Center while the slider is visible.
            outputVolume = Double(AVAudioSession.sharedInstance().outputVolume)
            volumeObserver = AVAudioSession.sharedInstance().observe(
                \.outputVolume,
                options: [.new]
            ) { session, _ in
                DispatchQueue.main.async {
                    outputVolume = Double(session.outputVolume)
                }
            }
        }
        .onDisappear {
            volumeObserver?.invalidate()
            volumeObserver = nil
        }
    }
}

/// UIViewRepresentable wrapping the system MPVolumeView. Hides the
/// system volume HUD on interaction (set showsVolumeSlider = true but
/// `showsRouteButton = false` because we don't want the AirPlay button
/// here) and uses the public UISlider subview (the same one the OS
/// itself uses) to read the current value.
private struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.backgroundColor = .clear
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        // No updates needed — MPVolumeView is self-managing.
    }
}

// MARK: - Player Control Button
struct PlayerControlButton: View {
    let icon: String
    let size: CGFloat
    var isEnabled: Bool = true
    var isActive: Bool = false
    let action: () -> Void
    
    var label: String {
        switch icon {
        case "backward.fill": return "Previous track"
        case "forward.fill": return "Next track"
        case "shuffle": return isActive ? "Shuffle on" : "Shuffle off"
        case "repeat": return "Repeat off"
        case "repeat.1": return "Repeat one"
        case "list.bullet": return "Up Next"
        case "moon.fill": return isActive ? "Sleep timer on" : "Sleep timer"
        default: return icon
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .accentColor : (isEnabled ? .white : Theme.tertiaryText))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
        .disabled(!isEnabled)
        .buttonStyle(.pressable)
    }
}

// MARK: - More Action Button
struct MoreActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .contentShape(Rectangle())
        }
        // S15: add a11y label, hint, and button trait. The
        // `title` is already passed in by every call site, so
        // this is a one-line fix that turns the row from
        // invisible-to-VoiceOver ("Image" x 7) to a proper
        // tappable button announcement.
        .accessibilityLabel(title)
        .accessibilityHint("Double tap to activate")
        .accessibilityAddTraits(.isButton)
        .buttonStyle(.plain)
    }
}

// MARK: - Artwork Image
struct ArtworkImage: View {
    let url: URL?
    let size: CGFloat
    @State private var isLoaded = false
    
    var body: some View {
        ZStack {
            // Placeholder
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.cyberDim.opacity(0.2))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.3))
                        .foregroundColor(.cyberDim)
                )
            
            // Image with fade using cache
            if let url = url {
                CachedAsyncImage(url: url) {
                    EmptyView()
                }
                .opacity(isLoaded ? 1 : 0)
                .onAppear {
                    withAnimation(.easeIn(duration: 0.3)) {
                        isLoaded = true
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }
}

// MARK: - Artwork Background
struct ArtworkBackground: View {
    let url: URL?
    
    var body: some View {
        GeometryReader { geometry in
            if let url = url {
                CachedAsyncImage(url: url) {
                    Color.clear
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .blur(radius: 80)
                .opacity(0.3)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Cyberpunk Hero Shapes

/// Full clip shape: sharp edges, diagonal bottom slash (left low → right high, i.e. /)
struct CyberpunkHeroShape: Shape {
    var slashDrop: CGFloat = 40

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - slashDrop))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

/// Just the bottom diagonal — used for the glowing cyan accent stroke
struct CyberpunkDiagonalEdge: Shape {
    var slashDrop: CGFloat = 40

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - slashDrop))
        return path
    }
}

// MARK: - AirPlay Button
struct AirPlayButton: View {
    var body: some View {
        ZStack {
            AirPlayIcon()
                .frame(width: 22, height: 22)

            // Invisible but tappable route picker overlay
            AirPlayRoutePickerView()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }
}

// MARK: - AirPlay Icon
struct AirPlayIcon: View {
    var body: some View {
        Image(systemName: "airplayaudio")
            .font(.system(size: 20))
            .foregroundColor(.white)
            .accessibilityLabel("AirPlay")
    }
}

// MARK: - AirPlay Route Picker
struct AirPlayRoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let routePicker = AVRoutePickerView()
        routePicker.activeTintColor = .clear
        routePicker.tintColor = .clear
        routePicker.prioritizesVideoDevices = false
        
        // Ensure the picker is tappable by not disabling user interaction
        routePicker.isUserInteractionEnabled = true
        
        return routePicker
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Audio Settings View
struct AudioSettingsView: View {
    @StateObject private var crossfadeManager = CrossfadeManager.shared
    @StateObject private var adaptiveWalkDJ = AdaptiveWalkDJManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.cyberBackground.ignoresSafeArea()

                List {
                    // Crossfade Section
                    Section {
                        Toggle(isOn: Binding(
                            get: { crossfadeManager.isEnabled },
                            set: { crossfadeManager.isEnabled = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Crossfade")
                                    .font(.body)
                                    .foregroundColor(.white)
                                Text("Smoothly fade between songs")
                                    .font(.caption)
                                    .foregroundColor(.cyberDim)
                            }
                        }
                        .tint(Color.cyberCyan)
                        .listRowBackground(Color.cyberSurface)

                        if crossfadeManager.isEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Duration")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text("\(Int(crossfadeManager.duration)) seconds")
                                        .font(.subheadline)
                                        .foregroundColor(.cyberDim)
                                }

                                Slider(
                                    value: Binding(
                                        get: { crossfadeManager.duration },
                                        set: { crossfadeManager.duration = $0 }
                                    ),
                                    in: 1...5,
                                    step: 1
                                )
                                .tint(Color.cyberCyan)

                                HStack {
                                    Text("1s")
                                        .font(.caption2)
                                        .foregroundColor(.cyberDim)
                                    Spacer()
                                    Text("5s")
                                        .font(.caption2)
                                        .foregroundColor(.cyberDim)
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color.cyberSurface)
                        }
                    } header: {
                        Text("TRANSITIONS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberDim)
                    } footer: {
                        Text("Crossfade creates a smooth transition between songs by overlapping playback.")
                            .foregroundColor(.cyberDim)
                    }

                    // Gapless Section
                    Section {
                        Toggle(isOn: Binding(
                            get: { crossfadeManager.gaplessEnabled },
                            set: { crossfadeManager.gaplessEnabled = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Gapless Playback")
                                    .font(.body)
                                    .foregroundColor(.white)
                                Text("Remove silence between album tracks")
                                    .font(.caption)
                                    .foregroundColor(.cyberDim)
                            }
                        }
                        .tint(Color.cyberCyan)
                        .listRowBackground(Color.cyberSurface)
                    } header: {
                        Text("ALBUM PLAYBACK")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberDim)
                    } footer: {
                        Text("Gapless playback automatically removes silence between consecutive tracks from the same album.")
                            .foregroundColor(.cyberDim)
                    }

                    Section {
                        Toggle(isOn: Binding(
                            get: { adaptiveWalkDJ.isEnabled },
                            set: { adaptiveWalkDJ.setEnabled($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Adaptive Walk DJ")
                                    .font(.body)
                                    .foregroundColor(.white)
                                Text("Suggest a song when you're walking and nothing is currently playing")
                                    .font(.caption)
                                    .foregroundColor(.cyberDim)
                            }
                        }
                        .tint(Color.cyberCyan)
                        .listRowBackground(Color.cyberSurface)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(adaptiveWalkDJ.statusText)
                                .font(.subheadline)
                                .foregroundColor(.white)

                            if let lastSuggestionSummary = adaptiveWalkDJ.lastSuggestionSummary {
                                Text(lastSuggestionSummary)
                                    .font(.caption)
                                    .foregroundColor(.cyberDim)
                            }

                            Button {
                                adaptiveWalkDJ.triggerTestSuggestion()
                            } label: {
                                Label("Test Walk Suggestion", systemImage: "figure.walk")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.cyberCyan)
                            }
                            .disabled(!adaptiveWalkDJ.isEnabled)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.cyberSurface)
                    } header: {
                        Text("CONTEXT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberDim)
                    } footer: {
                        Text("Walk DJ uses motion activity and notifications to suggest a seed song, then hands off to the existing related-song flow.")
                            .foregroundColor(.cyberDim)
                    }

                    // S13: Loudness Normalization (Replay Gain).
                    // Previously the toggle was UserDefaults-backed but
                    // not exposed — users couldn't see or change it.
                    // Default stays `true` to preserve current behavior.
                    Section {
                        Toggle(isOn: Binding(
                            get: { PlayerState.replayGainEnabled },
                            set: { PlayerState.replayGainEnabled = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Loudness Normalization")
                                    .font(.body)
                                    .foregroundColor(.white)
                                Text("Match volume across tracks using Replay Gain metadata")
                                    .font(.caption)
                                    .foregroundColor(.cyberDim)
                            }
                        }
                        .tint(Color.cyberCyan)
                        .listRowBackground(Color.cyberSurface)
                    } header: {
                        Text("LOUDNESS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberDim)
                    } footer: {
                        Text("When enabled, the backend's Replay Gain value (in dB) is applied as a pre-gain multiplier so quiet songs and loud songs play at similar volumes.")
                            .foregroundColor(.cyberDim)
                    }

                    // Info Section
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: "waveform")
                                    .font(.title2)
                                    .foregroundColor(.cyberCyan)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("High Quality Audio")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.white)
                                    Text("AAC 128kbps streaming")
                                        .font(.caption)
                                        .foregroundColor(.cyberDim)
                                }
                            }

                            HStack(spacing: 12) {
                                Image(systemName: "network")
                                    .font(.title2)
                                    .foregroundColor(.cyberCyan)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Adaptive Streaming")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.white)
                                    Text("Optimized for your connection")
                                        .font(.caption)
                                        .foregroundColor(.cyberDim)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.cyberSurface)
                    } header: {
                        Text("AUDIO QUALITY")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberDim)
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .onAppear {
                    UITableView.appearance().backgroundColor = .clear
                }
                .onDisappear {
                    UITableView.appearance().backgroundColor = .systemGroupedBackground
                }
            }
            .navigationTitle("Audio")
            .navigationBarTitleDisplayMode(.large)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.cyberCyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview
struct FullPlayer_Previews: PreviewProvider {
    static var previews: some View {
        FullPlayer(isPresented: .constant(true))
            .preferredColorScheme(.dark)
    }
}
//
//  ShareSheet.swift
//  YTAudioPlayer
//
//  Sharing options with cards, QR codes, and links
//

import SwiftUI
import UIKit

struct ShareSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var showQRCode = false
    @State private var generatedCard: UIImage?
    @State private var isGenerating = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Preview Card
                if let card = generatedCard {
                    Image(uiImage: card)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 300)
                        .cornerRadius(CornerRadius.md)
                        .shadow(radius: 8)
                } else if isGenerating {
                    ProgressView("Generating card...")
                        .frame(height: 300)
                } else {
                    // Placeholder
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Theme.tertiaryText.opacity(0.2))
                        .frame(height: 300)
                        .overlay(
                            Text("Tap Generate to create share card")
                                .foregroundColor(.secondary)
                        )
                }
                
                // Action Buttons
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    ShareActionButton(
                        icon: "photo",
                        title: "Generate Card",
                        color: .blue
                    ) {
                        generateCard()
                    }
                    
                    ShareActionButton(
                        icon: "qrcode",
                        title: "QR Code",
                        color: .green
                    ) {
                        showQRCode = true
                    }
                    
                    ShareActionButton(
                        icon: "link",
                        title: "Copy Link",
                        color: .orange
                    ) {
                        copyLink()
                    }
                    
                    ShareActionButton(
                        icon: "square.and.arrow.up",
                        title: "Share",
                        color: .purple
                    ) {
                        shareTrack()
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showQRCode) {
                QRCodeView(track: track)
            }
            .onAppear {
                // Auto-generate card on appear
                generateCard()
            }
        }
    }
    
    private func generateCard() {
        isGenerating = true

        Task {
            let card = await ShareCardGenerator.generateCard(for: track)

            await MainActor.run {
                generatedCard = card
                isGenerating = false
            }
        }
    }
    
    private func copyLink() {
        let link = "https://music.youtube.com/watch?v=\(track.videoId)"
        UIPasteboard.general.string = link
        
        HapticManager.light()
        // Could show a toast here
    }
    
    private func shareTrack() {
        let items: [Any] = [
            "\(track.title) by \(track.displayArtist)",
            URL(string: "https://music.youtube.com/watch?v=\(track.videoId)")!
        ]
        
        let activityVC = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        
        // Present from top view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}

struct ShareActionButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(color)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.systemGray6))
            .cornerRadius(CornerRadius.md)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - QR Code View
struct QRCodeView: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let qr = qrImage {
                    Image(uiImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 250, height: 250)
                        .cornerRadius(CornerRadius.md)
                } else {
                    ProgressView()
                        .frame(width: 250, height: 250)
                }
                
                VStack(spacing: 8) {
                    Text(track.title)
                        .font(.headline)
                    Text(track.displayArtist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Text("Scan to listen on YouTube Music")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding()
            .navigationTitle("QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                generateQRCode()
            }
        }
    }
    
    private func generateQRCode() {
        let link = "https://music.youtube.com/watch?v=\(track.videoId)"
        qrImage = QRCodeGenerator.generate(from: link)
    }
}
