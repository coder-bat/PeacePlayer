//
//  FullPlayer.swift
//  YTAudioPlayer
//
//  Redesigned full-screen player with organized UX
//

import SwiftUI
import MediaPlayer
import AVKit

// Import settings views
import Foundation

struct FullPlayer: View {
    @ObservedObject private var playerState = PlayerState.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var showQueue = false
    @State private var showSleepTimer = false
    @State private var showLyrics = false
    @State private var showAirPlayPicker = false
    @State private var showAudioSettings = false
    @State private var showShareSheet = false
    
    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
            
            // Optional blur background from artwork
            ArtworkBackground(url: playerState.currentItem?.track.artworkURL)
            
            // Main content
            VStack(spacing: 0) {
                // Top bar with drag handle
                topBar
                
                ScrollView(showsIndicators: false) {
                    // Enable drag to dismiss from anywhere in ScrollView
                    // This works because ScrollView passes through vertical drags when at top
                    VStack(spacing: 24) {
                        // Large Artwork
                        artworkSection
                            .padding(.top, 10)
                        
                        // Track Info with Like button
                        trackInfoSection
                        
                        // Progress Bar
                        progressSection
                        
                        // Primary Controls (Previous/Play/Next)
                        primaryControlsSection
                            .padding(.vertical, 10)
                        
                        // Secondary Controls Row - organized in one line
                        secondaryControlsRow

                        // Volume Control
                        VolumeSlider()
                            .padding(.horizontal, 8)

                        // More Actions - Lyrics, Share, AirPlay
                        moreActionsRow
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
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
        // Swipe down to dismiss gesture
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only track vertical swipes
                    if value.translation.height > 0 && abs(value.translation.height) > abs(value.translation.width) {
                        // User is swiping down
                    }
                }
                .onEnded { value in
                    // Check if it's a downward swipe with sufficient distance
                    if value.translation.height > 100 && abs(value.translation.height) > abs(value.translation.width) {
                        HapticManager.medium()
                        dismiss()
                    }
                }
        )

    }
    
    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            // Drag handle
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
        ZStack {
            ArtworkImage(
                url: playerState.currentItem?.track.artworkURL,
                size: 300
            )
            
            // Loading overlay
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
        .frame(width: 300, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
    
    // MARK: - Track Info
    private var trackInfoSection: some View {
        VStack(spacing: 8) {
            Text(playerState.currentItem?.track.title ?? "")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 8) {
                Text(playerState.currentItem?.track.displayArtist ?? "")
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                
                LikeButton(trackId: playerState.currentItem?.track.videoId)
            }
        }
        .padding(.horizontal, 20)
    }
    
    // MARK: - Progress Section
    private var progressSection: some View {
        VStack(spacing: 6) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                    
                    // Progress
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: max(0, geometry.size.width * CGFloat(playerState.progress)), height: 4)
                    
                    // Draggable knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .shadow(radius: 4)
                        .offset(x: max(0, geometry.size.width * CGFloat(playerState.progress)) - 6)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let newProgress = min(max(0, Double(value.location.x / geometry.size.width)), 1)
                            playerState.seek(to: newProgress)
                        }
                )
            }
            .frame(height: 20)
            
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
    }
    
    // MARK: - Primary Controls
    private var primaryControlsSection: some View {
        HStack(spacing: 40) {
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
                    playerState.nextTrack()
                }
            )
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
    
    // MARK: - More Actions Row (Lyrics, Audio, Share, AirPlay)
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

// MARK: - Volume Slider
struct VolumeSlider: View {
    @State private var volume: Double = 0.7
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
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .accentColor : (isEnabled ? .white : .gray))
                .frame(width: 44, height: 44)
        }
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
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
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
                            Text("Smoothly fade between songs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if crossfadeManager.isEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Duration")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(crossfadeManager.duration)) seconds")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(
                                value: Binding(
                                    get: { crossfadeManager.duration },
                                    set: { crossfadeManager.duration = $0 }
                                ),
                                in: 1...5,
                                step: 1
                            )
                            
                            HStack {
                                Text("1s")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("5s")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Transitions")
                } footer: {
                    Text("Crossfade creates a smooth transition between songs by overlapping playback.")
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
                            Text("Remove silence between album tracks")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Album Playback")
                } footer: {
                    Text("Gapless playback automatically removes silence between consecutive tracks from the same album.")
                }
                
                // Info Section
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                                .frame(width: 32)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("High Quality Audio")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("AAC 128kbps streaming")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack(spacing: 12) {
                            Image(systemName: "network")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                                .frame(width: 32)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Adaptive Streaming")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Optimized for your connection")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Audio Quality")
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Audio")
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
}

// MARK: - Preview
struct FullPlayer_Previews: PreviewProvider {
    static var previews: some View {
        FullPlayer()
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
