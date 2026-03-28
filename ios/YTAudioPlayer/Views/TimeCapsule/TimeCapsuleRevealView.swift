//
//  TimeCapsuleRevealView.swift
//  YTAudioPlayer
//
//  Cinematic reveal when a time capsule is opened.
//

import SwiftUI

struct TimeCapsuleRevealView: View {
    let capsule: TimeCapsuleSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var phase: RevealPhase = .sealed
    @State private var noteOpacity: Double = 0
    @State private var artworkScale: CGFloat = 0.6

    private enum RevealPhase {
        case sealed, cracking, revealed
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Background glow
            if phase == .revealed {
                Circle()
                    .fill(Color.cyan.opacity(0.08))
                    .frame(width: 400, height: 400)
                    .blur(radius: 80)
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                Spacer()

                // Capsule / artwork
                ZStack {
                    if phase == .sealed {
                        sealedCapsuleView
                    } else {
                        artworkView
                    }
                }
                .frame(height: 280)

                Spacer().frame(height: 32)

                // Track info
                if phase == .revealed {
                    VStack(spacing: 6) {
                        Text(capsule.trackTitle)
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Text(capsule.trackArtist)
                            .font(.subheadline)
                            .foregroundColor(.cyberDim)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer().frame(height: 24)

                // Note reveal
                if phase == .revealed {
                    VStack(spacing: 12) {
                        if let mood = capsule.mood {
                            Text(mood)
                                .font(.largeTitle)
                        }

                        Text("You wrote on \(capsule.createdAt.formatted(.dateTime.month().day().year())):")
                            .font(.caption)
                            .foregroundColor(.cyan.opacity(0.7))

                        Text(capsule.noteText)
                            .font(.body)
                            .foregroundColor(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(16)
                    }
                    .opacity(noteOpacity)
                    .padding(.horizontal)
                }

                Spacer()

                // Actions
                if phase == .revealed {
                    VStack(spacing: 12) {
                        Button {
                            playTrack()
                        } label: {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Play This Song")
                            }
                            .foregroundColor(.black)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.cyan)
                            .cornerRadius(14)
                        }

                        Button("Close") { dismiss() }
                            .foregroundColor(.cyberDim)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if phase == .sealed {
                    Button {
                        openCapsule()
                    } label: {
                        Text("Open Capsule")
                            .foregroundColor(.cyan)
                            .fontWeight(.semibold)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .background(Color.cyan.opacity(0.15))
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            // If already opened, skip to revealed
            if capsule.isOpened {
                phase = .revealed
                noteOpacity = 1
                artworkScale = 1
            }
        }
    }

    // MARK: - Subviews

    private var sealedCapsuleView: some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.1))
                .frame(width: 200, height: 200)

            Image(systemName: "envelope.fill")
                .font(.system(size: 80))
                .foregroundColor(.cyan.opacity(0.6))
                .shadow(color: .cyan.opacity(0.3), radius: 20)
        }
    }

    private var artworkView: some View {
        CachedAsyncImage(url: capsule.artworkURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.cyberDim.opacity(0.2)
        }
        .frame(width: 240, height: 240)
        .cornerRadius(20)
        .shadow(color: .cyan.opacity(0.3), radius: 30)
        .scaleEffect(artworkScale)
    }

    // MARK: - Actions

    private func openCapsule() {
        guard capsule.isReadyToOpen || capsule.isOpened else { return }

        // Mark as opened
        _ = TimeCapsuleManager.shared.openCapsule(id: capsule.id)
        HapticManager.heavy()

        // Crack animation
        withAnimation(.easeInOut(duration: 0.4)) {
            phase = .cracking
        }

        // Reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                phase = .revealed
                artworkScale = 1.0
            }
            withAnimation(.easeIn(duration: 1.0).delay(0.5)) {
                noteOpacity = 1.0
            }
        }
    }

    private func playTrack() {
        // Search and play via PlayerState
        APIService.shared.search(query: "\(capsule.trackTitle) \(capsule.trackArtist)")
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { results in
                    if let match = results.first(where: { $0.videoId == capsule.videoId }) ?? results.first {
                        PlayerState.shared.play(track: match)
                    }
                }
            )
            .store(in: &RevealViewCancellables.shared.cancellables)
        dismiss()
    }
}

// Cancellable storage for the reveal view
private class RevealViewCancellables {
    static let shared = RevealViewCancellables()
    var cancellables = Set<AnyCancellable>()
}

import Combine
