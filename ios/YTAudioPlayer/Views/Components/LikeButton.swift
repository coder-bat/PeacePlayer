//
//  LikeButton.swift
//  YTAudioPlayer
//
//  Like/favorite button with animation
//

import SwiftUI

struct LikeButton: View {
    let trackId: String?
    @StateObject private var playlistManager = PlaylistManager.shared
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    
    private var isLiked: Bool {
        guard let trackId = trackId else { return false }
        return playlistManager.isLiked(trackId: trackId)
    }
    
    var body: some View {
        Button(action: toggleLike) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 20))
                .foregroundColor(isLiked ? .cyberMagenta : .cyberDim)
                .scaleEffect(isAnimating ? 1.3 : 1.0)
                .animation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.5), value: isAnimating)
                .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: isLiked)
        }
        .accessibilityLabel(isLiked ? "Unlike" : "Like")
        .disabled(trackId == nil)
    }
    
    private func toggleLike() {
        guard let trackId = trackId else { return }

        HapticManager.medium()
        isAnimating = true
        playlistManager.toggleLike(trackId: trackId)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isAnimating = false
        }
    }
}

// MARK: - Preview

struct LikeButton_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 20) {
            LikeButton(trackId: "test1")
            LikeButton(trackId: nil)
        }
    }
}
