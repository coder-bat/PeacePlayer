//
//  AntiAlgorithmView.swift
//  YTAudioPlayer
//
//  UI for the Anti-Algorithm: start exploring, session progress, stats.
//

import SwiftUI

struct AntiAlgorithmView: View {
    @StateObject private var engine = AntiAlgorithmEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tasteProfile: (artists: [(String, Int)], seedCount: Int)?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        if engine.isExploring {
                            activeSessionView
                        } else if engine.isLoading {
                            loadingView
                        } else {
                            startView
                        }

                        statsSection
                    }
                    .padding()
                }
            }
            .navigationTitle("Anti-Algorithm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        HapticManager.light()
                        dismiss()
                    }
                        .foregroundColor(.cyberDim)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { tasteProfile = engine.analyzeListeningHistory() }
    }

    // MARK: - Start View

    private var startView: some View {
        VStack(spacing: 20) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: "dice.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.orange)
            }

            Text("Break Your Bubble")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("We'll analyze your listening habits and\nqueue songs just outside your comfort zone")
                .font(.subheadline)
                .foregroundColor(.cyberDim)
                .multilineTextAlignment(.center)

            // Taste preview
            if let profile = tasteProfile, !profile.artists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your top artists")
                        .font(.caption)
                        .foregroundColor(.orange)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(profile.artists.prefix(8), id: \.0) { artist, count in
                            Text(artist)
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.cyberSurface.opacity(0.08))
                                .cornerRadius(8)
                        }
                    }
                }
                .padding()
                .background(Color.cyberSurface.opacity(0.03))
                .cornerRadius(12)
            }

            Button {
                HapticManager.medium()
                engine.startExplorationSession()
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                    Text("Start Exploring")
                        .fontWeight(.semibold)
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.orange)
                .cornerRadius(14)
            }
            .disabled(tasteProfile?.artists.isEmpty ?? true)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.orange)
                .scaleEffect(1.5)
            Text("Finding your frontier...")
                .font(.subheadline)
                .foregroundColor(.cyberDim)
        }
        .frame(height: 200)
    }

    // MARK: - Active Session

    private var activeSessionView: some View {
        VStack(spacing: 20) {
            // Session badge
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.orange)
                Text("Exploring...")
                    .font(.headline)
                    .foregroundColor(.orange)
                Spacer()
                Button("End") {
                    HapticManager.light()
                    engine.endExplorationSession()
                }
                    .foregroundColor(.cyberDim)
            }
            .padding()
            .background(Color.orange.opacity(0.08))
            .cornerRadius(12)

            // Queue
            if !engine.explorationQueue.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Frontier Queue")
                        .font(.caption)
                        .foregroundColor(.orange)

                    ForEach(engine.explorationQueue) { track in
                        HStack(spacing: 12) {
                            CachedAsyncImage(url: track.artworkURL) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Color.cyberDim.opacity(0.2)
                            }
                            .frame(width: 44, height: 44)
                            .cornerRadius(8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text(track.displayArtist)
                                    .font(.caption)
                                    .foregroundColor(.cyberDim)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }

                            Spacer()

                            Button {
                                PlayerState.shared.play(track: track)
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                .padding()
                .background(Color.cyberSurface.opacity(0.03))
                .cornerRadius(12)
            }

            // Session stats
            if let session = engine.currentSession {
                HStack(spacing: 24) {
                    StatPill(label: "Queued", value: "\(session.tracksQueued)", color: .orange)
                    StatPill(label: "Played", value: "\(session.tracksCompleted)", color: .green)
                    StatPill(label: "Skipped", value: "\(session.tracksSkipped)", color: Theme.tertiaryText)
                    StatPill(label: "Liked", value: "\(session.tracksLiked)", color: .cyan)
                }
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        let stats = engine.totalStats()
        guard stats.sessions > 0 else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                Text("Exploration History")
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 16) {
                    StatBlock(title: "Sessions", value: "\(stats.sessions)")
                    StatBlock(title: "Explored", value: "\(stats.tracksExplored)")
                    StatBlock(title: "Liked", value: "\(stats.liked)")
                }
            }
            .padding()
            .background(Color.cyberSurface.opacity(0.03))
            .cornerRadius(12)
        )
    }
}

// MARK: - Supporting Views

private struct StatPill: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.cyberDim)
        }
    }
}

private struct StatBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundColor(.orange)
            Text(title)
                .font(.caption)
                .foregroundColor(.cyberDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.cyberSurface.opacity(0.05))
        .cornerRadius(10)
    }
}

// end of file
