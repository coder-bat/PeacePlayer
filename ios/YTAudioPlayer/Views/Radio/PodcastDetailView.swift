import SwiftUI

struct PodcastDetailView: View {
    let show: PodcastShow
    @ObservedObject var viewModel: RadioViewModel
    @Environment(\.dismiss) private var dismiss

    // Deck design system (docs/design/deck-design-system.md §8 step 6).
    @ObservedObject private var featureFlags = FeatureFlags.shared
    private var deck: Bool { featureFlags.turntableHome }

    var body: some View {
        Group {
            if deck { deckBody } else { legacyBody }
        }
        .environment(\.deckStyle, deck)
        .task {
            viewModel.loadEpisodes(for: show)
        }
    }

    /// Deck: a walnut head over the room, the sleeve and name, then an
    /// "Episodes" ledge with the rows under it.
    private var deckBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Podcast")
                    .font(DeckType.screenTitle)
                    .foregroundColor(TurntableTokens.cream)
                Spacer(minLength: 8)
                DeckButton(title: "Done", kind: .card) { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .deckPlinth(cornerRadius: 0)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    deckHeader
                        .padding(.vertical, 22)
                    deckEpisodes
                }
                .padding(.bottom, 90)
            }
        }
        .background(DeckRoom())
        .preferredColorScheme(.dark)
    }

    private var deckHeader: some View {
        VStack(spacing: 14) {
            CachedAsyncImage(url: show.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    TurntableTokens.walnut
                    Image(systemName: "mic.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                }
            }
            .frame(width: 180, height: 180)
            .deckCover(cornerRadius: 3)

            VStack(spacing: 6) {
                Text(show.collectionName)
                    .font(DeckType.screenTitle)
                    .foregroundColor(TurntableTokens.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(show.artistName)
                    .font(DeckType.subtitle)
                    .foregroundColor(TurntableTokens.cream.opacity(0.55))
                    .lineLimit(1)
                Text(([show.displayGenres, "\(show.trackCount) episodes"].filter { !$0.isEmpty }).joined(separator: " · ").uppercased())
                    .font(DeckType.smallPrint)
                    .foregroundColor(TurntableTokens.brass)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(show.collectionName) by \(show.artistName), \(show.trackCount) episodes")
    }

    @ViewBuilder
    private var deckEpisodes: some View {
        if viewModel.isLoadingEpisodes {
            DeckLamp(color: DeckSignal.power, state: .working, size: 8)
                .padding(.vertical, 40)
                .accessibilityLabel("Loading episodes")
        } else if viewModel.currentEpisodes.isEmpty && viewModel.errorMessage != nil {
            VStack(spacing: 14) {
                Text("Failed to load episodes")
                    .font(DeckType.title)
                    .foregroundColor(TurntableTokens.cream)
                DeckButton(title: "Retry", symbol: "arrow.clockwise", kind: .card) {
                    viewModel.loadEpisodes(for: show)
                }
            }
            .padding(.vertical, 40)
        } else if viewModel.currentEpisodes.isEmpty {
            Text("No episodes available")
                .font(DeckType.title)
                .foregroundColor(TurntableTokens.cream.opacity(0.7))
                .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 0) {
                DeckLedge(title: "Episodes", count: viewModel.currentEpisodes.count)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                ForEach(viewModel.currentEpisodes) { episode in
                    PodcastEpisodeRow(episode: episode) {
                        viewModel.playEpisode(episode)
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var legacyBody: some View {
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
    @Environment(\.deckStyle) private var deck

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
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: the shared row, a metal play button, and a brass channel
    /// under it showing how far through the episode was left.
    private var deckBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            DeckTrackRow(
                title: episode.title,
                subtitle: [episode.formattedDate, episode.durationText].filter { !$0.isEmpty }.joined(separator: " · "),
                artworkURL: episode.artworkURL
            ) {
                DeckMetalButton(symbol: "play.fill", size: 28) {
                    onPlay()
                }
                .accessibilityLabel("Play \(episode.title)")
            }

            if hasProgress {
                GeometryReader { geo in
                    Capsule()
                        .fill(TurntableTokens.brass)
                        .frame(width: max(4, geo.size.width * progressFraction))
                }
                .frame(height: 4)
                .deckWell(Capsule())
                .accessibilityHidden(true)
            }

            if !episode.description.isEmpty {
                Button(action: { withAnimation(DeckMotion.move) { isExpanded.toggle() } }) {
                    Text(episode.description)
                        .font(DeckType.subtitle)
                        .foregroundColor(TurntableTokens.cream.opacity(0.55))
                        .lineLimit(isExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TurntableTokens.cream.opacity(0.08)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var legacyBody: some View {
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
