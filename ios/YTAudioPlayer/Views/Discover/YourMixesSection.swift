//
//  YourMixesSection.swift
//  YTAudioPlayer
//
//  Personalized mix cards
//

import SwiftUI

// MARK: - Mix Model
struct Mix: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let gradientColors: [Color]
    let previewArtwork: [URL]
}

struct YourMixesSection: View {
    @State private var mixes: [Mix] = []
    var onMixSelected: ((Mix) -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("Your Mixes")
                .font(.title2.bold())
                .padding(.horizontal)
            
            // Horizontal Scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(mixes) { mix in
                        MixCard(mix: mix, onTap: {
                            onMixSelected?(mix)
                        })
                    }
                }
                .padding(.horizontal)
            }
        }
        .task {
            generateMixes()
        }
    }
    
    private func generateMixes() {
        let history = DataManager.shared.recentlyPlayed
        
        mixes = [
            Mix(
                title: "Your Mix",
                subtitle: "Made for you",
                gradientColors: [.purple, .pink],
                previewArtwork: history.prefix(4).compactMap { $0.artworkURL }
            ),
            Mix(
                title: "Discover Weekly",
                subtitle: "New music every week",
                gradientColors: [.blue, .cyan],
                previewArtwork: []
            ),
            Mix(
                title: "Liked Songs",
                subtitle: "Your favorites",
                gradientColors: [.red, .orange],
                previewArtwork: []
            ),
            Mix(
                title: "On Repeat",
                subtitle: "Songs you love",
                gradientColors: [.green, .teal],
                previewArtwork: []
            )
        ]
    }
}

struct MixCard: View {
    let mix: Mix
    var onTap: (() -> Void)?
    
    var body: some View {
        Button(action: {
            HapticManager.medium()
            onTap?()
        }) {
            ZStack {
                // Gradient background
                LinearGradient(
                    colors: mix.gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                // Content
                VStack(alignment: .leading, spacing: 8) {
                    // Title area
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mix.title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text(mix.subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    Spacer()
                    
                    // Preview artwork grid
                    if !mix.previewArtwork.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(0..<min(mix.previewArtwork.count, 4), id: \.self) { index in
                                CachedAsyncImage(url: mix.previewArtwork[index]) {
                                    Color.white.opacity(0.2)
                                }
                                .frame(width: 40, height: 40)
                                .cornerRadius(4)
                            }
                        }
                    } else {
                        // Default icon
                        Image(systemName: "music.note")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding()
            }
        }
        .buttonStyle(.pressable)
        .frame(width: 170, height: 210)
        .cornerRadius(12)
    }
}
