//
//  LyricsView.swift
//  YTAudioPlayer
//
//  Lyrics display with auto-scroll and real API integration
//

import SwiftUI
import Combine

struct LyricsView: View {
    @StateObject private var playerState = PlayerState.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State private var lyrics: [LyricsLine] = []
    @State private var currentLineIndex = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var timer: Timer?
    @State private var cancellables = Set<AnyCancellable>()

    // S18 / P1-6: Apple Music's signature lyrics feature — when
    // the user touches the lyrics to read ahead (or scroll back),
    // auto-scroll pauses. Tapping "Follow again" resumes.
    // Without this, the next 0.3s tick yanks the user back to
    // the current line, which is the #1 most common lyrics-UX
    // complaint in any music app.
    @State private var userScrolled: Bool = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.black.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else if let error = error {
                    errorView(message: error)
                } else if lyrics.isEmpty {
                    emptyView
                } else {
                    lyricsListView
                }
            }
            // S18 / P1-6: "Follow again" pill. Shown only when the
            // user has grabbed the lyrics. Resets userScrolled
            // so the next onChange(of: currentLineIndex) tick
            // scrolls to the new current line. The .animation
            // matches the auto-scroll animation for a smooth
            // resume.
            .overlay(alignment: .bottom) {
                if userScrolled && !lyrics.isEmpty {
                    FollowAgainPill {
                        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.3)) {
                            userScrolled = false
                        }
                    }
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: userScrolled)
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            loadLyrics()
            startLyricsTimer()
        }
        .onDisappear {
            stopLyricsTimer()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            
            Text("Loading lyrics...")
                .foregroundColor(Theme.tertiaryText)
        }
    }
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 60))
                .foregroundColor(Theme.tertiaryText)
            
            Text("No Lyrics Available")
                .font(.title3)
                .foregroundColor(.white)
            
            Text("Lyrics haven't been added for this track yet.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(Theme.warning)
            
            Text("Couldn't Load Lyrics")
                .font(.title3)
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button("Try Again") {
                loadLyrics()
            }
            .padding(.top, 8)
        }
    }
    
    private var lyricsListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    // Track info header
                    VStack(spacing: 8) {
                        Text(playerState.currentItem?.track.title ?? "")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)

                        Text(playerState.currentItem?.track.displayArtist ?? "")
                            .font(.headline)
                            .foregroundColor(Theme.tertiaryText)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 40)

                    // Lyrics lines
                    ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                        Text(line.text)
                            .font(.system(size: isCurrentLine(index) ? 24 : 20, weight: isCurrentLine(index) ? .bold : .regular))
                            .foregroundColor(isCurrentLine(index) ? .white : Theme.tertiaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .id(index)
                            .onTapGesture {
                                // Seek to this line's time
                                if playerState.duration > 0 {
                                    HapticManager.light()
                                    playerState.seek(to: line.time / playerState.duration)
                                }
                            }
                            .scaleEffect(isCurrentLine(index) ? 1.05 : 1.0)
                            .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: currentLineIndex)
                    }

                    Spacer(minLength: 100)
                }
            }
            // S18 / P1-6: freeze-on-touch. The .simultaneousGesture
            // (not .onChange on the ScrollView itself) is key —
            // the ScrollView's own gesture needs to keep working
            // for the user to actually scroll. We just observe
            // that a scroll happened and pause auto-follow.
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { _ in
                        if !userScrolled {
                            userScrolled = true
                        }
                    }
            )
            .onChange(of: currentLineIndex) { _, newIndex in
                // S18 / P1-6: only auto-scroll if the user hasn't
                // grabbed the lyrics. Once they touch-scroll, the
                // next tick would yank them back to the current
                // line — the #1 lyrics-UX complaint. Resume via
                // the "Follow again" pill.
                guard !userScrolled else { return }
                withAnimation(reduceMotion ? .none : .easeOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
    
    private func isCurrentLine(_ index: Int) -> Bool {
        index == currentLineIndex
    }
    
    private func loadLyrics() {
        guard let videoId = playerState.currentItem?.track.videoId else {
            error = "No track currently playing"
            return
        }
        
        isLoading = true
        error = nil
        lyrics = []
        
        APIService.shared.getLyrics(videoId: videoId)
            .sink(receiveCompletion: { completion in
                self.isLoading = false
                if case .failure(let apiError) = completion {
                    if case .httpError(let code, _) = apiError, code == 404 {
                        self.lyrics = []
                    } else {
                        self.error = "Failed to load lyrics"
                    }
                }
            }, receiveValue: { parsedLyrics in
                self.lyrics = parsedLyrics
                self.currentLineIndex = 0
            })
            .store(in: &cancellables)
    }
    
    private func startLyricsTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            updateCurrentLine()
        }
    }
    
    private func stopLyricsTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateCurrentLine() {
        let currentTime = playerState.currentTime
        
        // Find the current line based on time
        var newIndex = 0
        for (index, line) in lyrics.enumerated() {
            if currentTime >= line.time {
                newIndex = index
            } else {
                break
            }
        }
        
        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }
    }
}

struct LyricsView_Previews: PreviewProvider {
    static var previews: some View {
        LyricsView()
            .preferredColorScheme(.dark)
    }
}

// S18 / P1-6: "Follow again" pill. Apple Music shows a small
// pill at the bottom of the lyrics when the user has scrolled
// away from auto-follow. Tapping it re-engages auto-follow.
private struct FollowAgainPill: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Follow again")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Theme.cyberCyan)
                    .shadow(color: Theme.cyberCyan.opacity(0.4), radius: 8, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Follow lyrics again")
    }
}
