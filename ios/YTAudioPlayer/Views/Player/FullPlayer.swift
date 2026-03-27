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
    @ObservedObject private var playerState = PlayerState.shared
    @ObservedObject private var playlistManager = PlaylistManager.shared
    @ObservedObject private var songMemoryManager = SongMemoryManager.shared
    @Binding var isPresented: Bool

    private func dismiss() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
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
    @State private var dominantColor: Color = .clear
    @State private var dragOffset: CGFloat = 0
    @State private var scrollAtTop: Bool = true
    @State private var showScrubberThumb = false
    @State private var scrubberHideTask: Task<Void, Never>? = nil
    @State private var isTrackInfoExpanded = false
    @State private var likePulse = false
    @State private var waveformPeaks: [Float]? = nil
    @State private var showingVisualizer = false
    @State private var showTimeCapsule = false
    @State private var showTimeCapsuleVault = false
    @State private var showAntiAlgorithm = false
    @StateObject private var hapticEngine = HapticSymphonyEngine.shared

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
                    .animation(.easeInOut(duration: 0.8), value: dominantColor)

                // Optional blur background from artwork
                ArtworkBackground(url: playerState.currentItem?.track.artworkURL)

                // Main content — portrait or landscape
                if isLandscape {
                    landscapeContent(geo: geo)
                } else {
                    portraitContent
                }
            }
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard !isLandscape, scrollAtTop else { return }
                        let height = value.translation.height
                        if height > 0 {
                            dragOffset = height * 0.85
                        } else {
                            dragOffset = height * 0.05
                        }
                    }
                    .onEnded { value in
                        guard !isLandscape, scrollAtTop else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                dragOffset = 0
                            }
                            return
                        }
                        if value.translation.height > 100 || value.predictedEndTranslation.height > 250 {
                            HapticManager.medium()
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
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
            .onChange(of: playerState.showQueue) { shouldShow in
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
            .offset(y: dragOffset)
            .onAppear {
                extractDominantColor()
            }
            .onChange(of: playerState.currentItem?.track.videoId) { _ in
                extractDominantColor()
                isTrackInfoExpanded = false
            }
        }
    }

    // MARK: - Portrait Layout
    private var portraitContent: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(showsIndicators: false) {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: FullPlayerScrollOffsetKey.self,
                        value: geo.frame(in: .named("fullPlayerScroll")).minY
                    )
                }
                .frame(height: 0)

                VStack(spacing: 10) {
                    artworkSection
                        .padding(.top, 6)
                    trackInfoSection
                    playbackControlsSection
                    VolumeSlider()
                        .padding(.horizontal, 8)
                    moreActionsRow
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
            }
            .coordinateSpace(name: "fullPlayerScroll")
            .onPreferenceChange(FullPlayerScrollOffsetKey.self) { value in
                scrollAtTop = value >= -10
            }
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
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                ZStack {
                    ArtworkImage(
                        url: playerState.currentItem?.track.artworkURL,
                        size: artworkSize
                    )
                    if playerState.playbackState.isLoading {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.5))
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
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(currentTrackIsLiked ? Color.red.opacity(0.55) : Color.clear, lineWidth: currentTrackIsLiked ? 1.5 : 0)
                )
                .shadow(
                    color: currentTrackIsLiked ? Color.red.opacity(likePulse ? 0.45 : 0.22) : .black.opacity(0.3),
                    radius: currentTrackIsLiked ? (likePulse ? 26 : 18) : 20,
                    x: 0,
                    y: 10
                )
                .scaleEffect(playerState.playbackState.isPlaying ? 1.0 : 0.94)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: playerState.playbackState.isPlaying)
                .animation(.easeInOut(duration: 0.25), value: currentTrackIsLiked)
                .animation(.easeInOut(duration: 0.25), value: likePulse)
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
        guard let url = playerState.currentItem?.track.artworkURL else { return }
        Task.detached(priority: .userInitiated) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
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

            let color = Color(
                red: Double(bitmap[0]) / 255.0,
                green: Double(bitmap[1]) / 255.0,
                blue: Double(bitmap[2]) / 255.0
            )
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.8)) {
                    dominantColor = color
                }
            }
        }
    }
    
    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            // Drag handle — visual only, actual drag handled by simultaneousGesture on ZStack
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 5)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            dismiss()
        }
    }
    
    // MARK: - Artwork Section
    private var artworkSection: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width - 48, 380)
            ZStack {
                // Artwork view
                ZStack {
                    ArtworkImage(
                        url: playerState.currentItem?.track.artworkURL,
                        size: size
                    )

                    if playerState.playbackState.isLoading {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.5))
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
                .opacity(showingVisualizer ? 0 : 1)
                .rotation3DEffect(.degrees(showingVisualizer ? -90 : 0), axis: (x: 0, y: 1, z: 0))

                // Visualizer view
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black)

                    NeuralFreqVisualizer(engine: AudioVisualizerEngine.shared, style: .neural)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .opacity(showingVisualizer ? 1 : 0)
                .rotation3DEffect(.degrees(showingVisualizer ? 0 : 90), axis: (x: 0, y: 1, z: 0))
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        showingVisualizer ? Color.cyberCyan.opacity(0.6) :
                            (currentTrackIsLiked ? Color.red.opacity(0.55) : Color.clear),
                        lineWidth: (showingVisualizer || currentTrackIsLiked) ? 1.5 : 0
                    )
            )
            .shadow(
                color: showingVisualizer
                    ? Color.cyberCyan.opacity(0.35)
                    : (currentTrackIsLiked ? Color.red.opacity(likePulse ? 0.45 : 0.22) : Color.black.opacity(0.3)),
                radius: showingVisualizer ? 24 : (currentTrackIsLiked ? (likePulse ? 26 : 18) : 20),
                x: 0, y: 10
            )
            .scaleEffect(playerState.playbackState.isPlaying ? 1.0 : 0.94)
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: showingVisualizer)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: playerState.playbackState.isPlaying)
            .animation(.easeInOut(duration: 0.25), value: currentTrackIsLiked)
            .animation(.easeInOut(duration: 0.25), value: likePulse)
            .frame(maxWidth: .infinity, alignment: .center)
            .onTapGesture(count: 2) {
                if !showingVisualizer { toggleCurrentTrackLike() }
            }
            .gesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .local)
                    .onEnded { value in
                        let horizontal = abs(value.translation.width)
                        let vertical = abs(value.translation.height)
                        guard horizontal > vertical else { return }
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                            showingVisualizer.toggle()
                        }
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
    
    // MARK: - Track Info
    private var trackInfoSection: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
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
    private var progressSection: some View {
        VStack(spacing: 4) {
            if let peaks = waveformPeaks {
                // WAVEFORM_SEEK: SoundCloud-style symmetric waveform scrubber
                WaveformSeekBar(
                    peaks: peaks,
                    progress: Binding(
                        get: { playerState.progress },
                        set: { _ in }
                    ),
                    onSeek: { newProgress in
                        playerState.seek(to: newProgress)
                        withAnimation(.easeIn(duration: 0.15)) { showScrubberThumb = true }
                        scrubberHideTask?.cancel()
                        scrubberHideTask = Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                withAnimation(.easeOut(duration: 0.2)) { showScrubberThumb = false }
                            }
                        }
                    },
                    onDragChange: { isDragging in
                        withAnimation(.easeInOut(duration: 0.15)) { showScrubberThumb = isDragging }
                    }
                )
                .frame(height: 48)
                .transition(.opacity)
            } else {
                // Fallback flat bar while waveform loads
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white)
                            .frame(width: max(0, geometry.size.width * CGFloat(playerState.progress)), height: 4)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(radius: 4)
                            .offset(x: max(0, geometry.size.width * CGFloat(playerState.progress)) - 7)
                            .opacity(showScrubberThumb ? 1 : 0)
                            .animation(.easeInOut(duration: 0.15), value: showScrubberThumb)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newProgress = min(max(0, Double(value.location.x / geometry.size.width)), 1)
                                playerState.seek(to: newProgress)
                                withAnimation(.easeIn(duration: 0.15)) { showScrubberThumb = true }
                                scrubberHideTask?.cancel()
                            }
                            .onEnded { _ in
                                HapticManager.light()
                                scrubberHideTask?.cancel()
                                scrubberHideTask = Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    guard !Task.isCancelled else { return }
                                    await MainActor.run {
                                        withAnimation(.easeOut(duration: 0.2)) { showScrubberThumb = false }
                                    }
                                }
                            }
                    )
                }
                .frame(height: 20)
            }

            // Time labels
            HStack {
                Text(playerState.currentTimeFormatted)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)

                Spacer()

                Text(playerState.durationFormatted)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
        .task(id: currentTrack?.videoId) {
            waveformPeaks = nil
            guard let videoId = currentTrack?.videoId else { return }
            let peaks = await WaveformService.shared.waveform(for: videoId)
            withAnimation(.easeIn(duration: 0.3)) {
                waveformPeaks = peaks
            }
        }
    }

    private var playbackControlsSection: some View {
        VStack(spacing: 8) {
            progressSection
            primaryControlsSection
                .padding(.bottom, 6)
            secondaryControlsRow
        }
    }
    
    // MARK: - Primary Controls
    private var primaryControlsSection: some View {
        HStack(spacing: 34) {
            // Previous
            PlayerControlButton(
                icon: "backward.fill",
                size: 28,
                isEnabled: playerState.hasPreviousTrack,
                action: {
                    HapticManager.medium()
                    playerState.previousTrack()
                }
            )
            
            // Play/Pause (larger) with loading state
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.white.opacity(0.3), radius: 10)
                
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
            
            // Next
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
    private func toggleCurrentTrackLike() {
        guard let trackId = currentTrack?.videoId else { return }

        HapticManager.medium()
        playlistManager.toggleLike(trackId: trackId)

        withAnimation(.easeInOut(duration: 0.18)) {
            likePulse = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeInOut(duration: 0.22)) {
                likePulse = false
            }
        }
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
        .cornerRadius(12)
    }
    
    // MARK: - More Actions Row (Lyrics, Memory, Audio, Share, AirPlay)
    private var moreActionsRow: some View {
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

            MoreActionButton(
                icon: songMemoryManager.hasMemory(for: playerState.currentItem?.track) ? "sparkles.rectangle.stack.fill" : "square.and.pencil",
                title: "Memory",
                action: {
                    HapticManager.light()
                    showSongMemory = true
                }
            )

            // Haptic Symphony
            if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
                MoreActionButton(
                    icon: hapticEngine.isActive ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle",
                    title: "Haptic",
                    action: {
                        HapticManager.light()
                        if hapticEngine.isActive {
                            hapticEngine.stop()
                        } else {
                            hapticEngine.start()
                        }
                    }
                )
            }

            // Time Capsule (tap = bury, long-press = vault)
            Button {
                HapticManager.light()
                showTimeCapsule = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                    Text("Capsule")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 60)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    HapticManager.medium()
                    showTimeCapsuleVault = true
                }
            )
            
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
            
            // AirPlay / Output Device
            AirPlayButton()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
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
struct VolumeSlider: View {
    @State private var volume: Double = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 14))
                .foregroundColor(.gray)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)

                    // Fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: max(0, geometry.size.width * CGFloat(volume)), height: 4)

                    // Draggable knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: isDragging ? 14 : 10, height: isDragging ? 14 : 10)
                        .shadow(radius: isDragging ? 6 : 3)
                        .offset(x: max(0, geometry.size.width * CGFloat(volume)) - (isDragging ? 7 : 5))
                        .animation(.easeInOut(duration: 0.1), value: isDragging)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let newVolume = min(max(0, Double(value.location.x / geometry.size.width)), 1)
                            volume = newVolume
                            // Set system volume
                            MPVolumeView.setVolume(Float(newVolume))
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
            }
            .frame(height: 44)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
        .onAppear {
            volume = Double(AVAudioSession.sharedInstance().outputVolume)
        }
    }
}

// MARK: - MPVolumeView Extension
extension MPVolumeView {
    static func setVolume(_ volume: Float) {
        let volumeView = MPVolumeView()
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                slider.value = volume
            }
        }
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
                .foregroundColor(isActive ? .accentColor : (isEnabled ? .white : .gray))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
        .disabled(!isEnabled)
        .buttonStyle(.plain)
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
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
        }
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
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.3))
                        .foregroundColor(.gray)
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
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

// MARK: - AirPlay Button
struct AirPlayButton: View {
    var body: some View {
        ZStack {
            // Visual content
            VStack(spacing: 6) {
                AirPlayIcon()
                    .frame(width: 20, height: 20)
                
                Text("AirPlay")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            // Invisible but tappable route picker overlay
            AirPlayRoutePickerView()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
    }
}

// MARK: - AirPlay Icon
struct AirPlayIcon: View {
    var body: some View {
        Image(systemName: "airplayaudio")
            .font(.system(size: 20))
            .foregroundColor(.white)
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
    @ObservedObject private var adaptiveWalkDJ = AdaptiveWalkDJManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
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
        NavigationView {
            VStack(spacing: 24) {
                // Preview Card
                if let card = generatedCard {
                    Image(uiImage: card)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 300)
                        .cornerRadius(12)
                        .shadow(radius: 8)
                } else if isGenerating {
                    ProgressView("Generating card...")
                        .frame(height: 300)
                } else {
                    // Placeholder
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
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
            .cornerRadius(12)
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
        NavigationView {
            VStack(spacing: 24) {
                if let qr = qrImage {
                    Image(uiImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 250, height: 250)
                        .cornerRadius(12)
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
