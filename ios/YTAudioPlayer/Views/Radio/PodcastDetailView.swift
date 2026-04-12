import SwiftUI

struct PodcastDetailView: View {
    let show: PodcastShow
    @ObservedObject var viewModel: RadioViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Theme.cyberBackground.ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Dismiss handle
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 36, height: 5)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    
                    // Close button
                    HStack {
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.cyberDim)
                                .padding(15)
                                .background(Circle().fill(Theme.cyberSurface))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    
                    headerSection
                    
                    Divider()
                        .background(Theme.cyberDim.opacity(0.2))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    
                    episodesList
                }
                .padding(.bottom, 90)
            }
        }
        .task {
            viewModel.loadEpisodes(for: show)
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            CachedAsyncImage(url: show.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Theme.cyberSurface
                    Image(systemName: "mic.fill")
                        .font(.system(size: 48))
                        .foregroundColor(Theme.cyberMagenta.opacity(0.4))
                }
            }
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
            .shadow(color: Theme.cyberMagenta.opacity(0.2), radius: 20, y: 10)
            
            VStack(spacing: 6) {
                Text(show.collectionName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                
                Text(show.artistName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.cyberMagenta)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                if !show.displayGenres.isEmpty {
                    Text(show.displayGenres)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                }
                
                Text("\(show.trackCount) episodes")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            }
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(show.collectionName) by \(show.artistName), \(show.trackCount) episodes")
    }
    
    // MARK: - Episodes
    
    private var episodesList: some View {
        LazyVStack(spacing: 0) {
            if viewModel.isLoadingEpisodes {
                ForEach(0..<5, id: \.self) { _ in
                    episodeShimmer
                }
            } else if viewModel.currentEpisodes.isEmpty && viewModel.errorMessage != nil {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundColor(Theme.cyberDim)
                    Text("Failed to load episodes")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.tertiaryText)
                    Button(action: {
                        viewModel.loadEpisodes(for: show)
                    }) {
                        Text("RETRY")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.cyberCyan))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if viewModel.currentEpisodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundColor(Theme.cyberDim)
                    Text("No episodes available")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                HStack {
                    Text("EPISODES")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                    Spacer()
                    Text("\(viewModel.currentEpisodes.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyberCyan)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                
                ForEach(viewModel.currentEpisodes) { episode in
                    PodcastEpisodeRow(episode: episode) {
                        viewModel.playEpisode(episode)
                    }
                    .padding(.horizontal, 20)
                    
                    Divider()
                        .background(Theme.cyberDim.opacity(0.2))
                        .padding(.horizontal, 20)
                }
            }
        }
    }
    
    private var episodeShimmer: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: CornerRadius.xs)
                .fill(Theme.cyberDim.opacity(0.15))
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.cyberDim.opacity(0.15))
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.cyberDim.opacity(0.1))
                    .frame(width: 120, height: 10)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .shimmer()
    }
}

// MARK: - Episode Row

struct PodcastEpisodeRow: View {
    let episode: PodcastEpisode
    let onPlay: () -> Void
    @State private var isExpanded = false
    
    private var savedPosition: Double {
        UserDefaults.standard.double(forKey: "podcast_position_\(episode.guid)")
    }
    
    private var hasProgress: Bool {
        savedPosition > 0 && episode.durationSeconds > 0
    }
    
    private var progressFraction: Double {
        guard episode.durationSeconds > 0 else { return 0 }
        return min(savedPosition / Double(episode.durationSeconds), 1.0)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                CachedAsyncImage(url: episode.artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Theme.cyberSurface
                        Image(systemName: "waveform")
                            .foregroundColor(Theme.cyberMagenta.opacity(0.3))
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xs))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    
                    HStack(spacing: 8) {
                        Text(episode.formattedDate)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.cyberDim)
                        
                        if !episode.durationText.isEmpty {
                            Text("·")
                                .foregroundColor(Theme.cyberDim)
                            Text(episode.durationText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.cyberDim)
                        }
                    }
                    
                    if hasProgress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Theme.cyberDim.opacity(0.2))
                                Capsule()
                                    .fill(Theme.cyberMagenta)
                                    .frame(width: geo.size.width * progressFraction)
                                    .animation(.easeIn(duration: 0.3), value: progressFraction)
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 2)
                    }
                }
                
                Spacer()
                
                Button(action: onPlay) {
                    Image(systemName: hasProgress ? "play.circle.fill" : "play.circle")
                        .font(.system(size: 32))
                        .foregroundColor(Theme.cyberMagenta)
                        .contentShape(Circle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(episode.title)")
            }
            
            if !episode.description.isEmpty {
                Button(action: { withAnimation { isExpanded.toggle() } }) {
                    Text(episode.description)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.tertiaryText)
                        .lineLimit(isExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(episode.title), \(episode.formattedDate), \(episode.durationText)")
        .accessibilityHint("Double tap to play episode")
    }
}
