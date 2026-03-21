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
    
    @State private var lyrics: [LyricsLine] = []
    @State private var currentLineIndex = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var timer: Timer?
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        NavigationView {
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
                .foregroundColor(.gray)
        }
    }
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
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
                .foregroundColor(.orange)
            
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
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                    
                    // Lyrics lines
                    ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                        Text(line.text)
                            .font(.system(size: isCurrentLine(index) ? 24 : 20, weight: isCurrentLine(index) ? .bold : .regular))
                            .foregroundColor(isCurrentLine(index) ? .white : .gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .id(index)
                            .onTapGesture {
                                // Seek to this line's time
                                if playerState.duration > 0 {
                                    playerState.seek(to: line.time / playerState.duration)
                                }
                            }
                            .scaleEffect(isCurrentLine(index) ? 1.05 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: currentLineIndex)
                    }
                    
                    Spacer(minLength: 100)
                }
            }
            .onChange(of: currentLineIndex) { newIndex in
                withAnimation(.easeOut(duration: 0.3)) {
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
