import SwiftUI

// MARK: - RadioView

struct RadioView: View {
    @ObservedObject var viewModel: RadioViewModel
    @State private var showPodcastDetail: PodcastShow?

    var body: some View {
        ZStack {
            Theme.cyberBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                headerSection
                sectionPicker
                searchBar

                ScrollView(showsIndicators: false) {
                    switch viewModel.selectedSection {
                    case .stations:
                        stationsSection
                    case .podcasts:
                        podcastsSection
                    case .songRadio:
                        songRadioSection
                    }

                    Spacer(minLength: 100)
                }
            }
        }
        .task {
            viewModel.loadTopStations()
            viewModel.loadTopPodcasts()
        }
        .sheet(item: $showPodcastDetail) { show in
            PodcastDetailView(show: show, viewModel: viewModel)
        }
    }

    // MARK: - Header

    var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("RADIO")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("stations · podcasts · song radio")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Section Picker

    var sectionPicker: some View {
        HStack(spacing: 8) {
            ForEach(RadioSection.allCases, id: \.self) { section in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectedSection = section
                        viewModel.searchText = ""
                    }
                    HapticManager.light()
                }) {
                    Text(section.rawValue.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(viewModel.selectedSection == section ? .black : Theme.cyberDim)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(viewModel.selectedSection == section ? Theme.cyberCyan : Theme.cyberSurface)
                        )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Search Bar

    var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.cyberDim)
            TextField(searchPlaceholder, text: $viewModel.searchText)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white)
            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.cyberDim)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(Theme.cyberSurface)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    var searchPlaceholder: String {
        switch viewModel.selectedSection {
        case .stations: return "Search radio stations..."
        case .podcasts: return "Search podcasts..."
        case .songRadio: return "Search tracks..."
        }
    }

    // MARK: - Stations Section

    var stationsSection: some View {
        LazyVStack(spacing: 20) {
            genreChips(genres: RadioViewModel.radioGenres) { genre in
                viewModel.loadStationsByGenre(genre)
            }

            if !viewModel.searchText.isEmpty {
                stationsList(viewModel.stationSearchResults, title: "SEARCH_RESULTS")
            } else if !viewModel.selectedGenre.isEmpty {
                stationsList(viewModel.genreStations, title: viewModel.selectedGenre.uppercased())
            } else {
                sectionHeader("TOP_STATIONS", count: viewModel.topStations.count)

                if viewModel.isLoadingStations && viewModel.topStations.isEmpty {
                    shimmerCards(count: 5)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(viewModel.topStations.prefix(15)) { station in
                                RadioStationCard(station: station) {
                                    viewModel.playStation(station)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    stationsList(Array(viewModel.topStations.dropFirst(15)), title: "MORE_STATIONS")
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Podcasts Section

    var podcastsSection: some View {
        LazyVStack(spacing: 20) {
            genreChips(genres: RadioViewModel.podcastGenres) { genre in
                viewModel.searchPodcasts(query: genre)
            }

            if !viewModel.searchText.isEmpty {
                podcastList(viewModel.podcastSearchResults, title: "SEARCH_RESULTS")
            } else {
                sectionHeader("TOP_PODCASTS", count: viewModel.topPodcasts.count)

                if viewModel.isLoadingPodcasts && viewModel.topPodcasts.isEmpty {
                    shimmerCards(count: 5)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(viewModel.topPodcasts.prefix(10)) { show in
                                PodcastCard(show: show) {
                                    showPodcastDetail = show
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    podcastList(Array(viewModel.topPodcasts.dropFirst(10)), title: "MORE_PODCASTS")
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Song Radio Section

    var songRadioSection: some View {
        LazyVStack(spacing: 20) {
            if !viewModel.recentSongRadios.isEmpty {
                sectionHeader("RECENT_RADIOS", count: viewModel.recentSongRadios.count)

                ForEach(viewModel.recentSongRadios) { track in
                    Button(action: {
                        viewModel.startSongRadio(from: track)
                    }) {
                        HStack(spacing: 12) {
                            CachedAsyncImage(url: track.artworkURL) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Theme.cyberSurface
                            }
                            .frame(width: 50, height: 50)
                            .cornerRadius(CornerRadius.sm)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Radio based on")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(Theme.cyberDim)
                                Text(track.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Text(track.displayArtist)
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.tertiaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                                .foregroundColor(Theme.cyberCyan)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .fill(Theme.cyberSurface)
                        )
                    }
                    .padding(.horizontal, 20)
                }
            }

            if viewModel.isLoadingSongRadio {
                ProgressView()
                    .tint(Theme.cyberCyan)
                    .padding(40)
            } else if let seed = viewModel.songRadioSeed, !viewModel.songRadioTracks.isEmpty {
                sectionHeader("RADIO: \(seed.title.uppercased().prefix(20))", count: viewModel.songRadioTracks.count)

                ForEach(viewModel.songRadioTracks) { track in
                    SongRadioRow(track: track) {
                        PlayerState.shared.play(track: track)
                    }
                    .padding(.horizontal, 20)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "radio")
                        .font(.system(size: 48))
                        .foregroundColor(Theme.cyberDim)
                    Text("Start Song Radio")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("Use \"Start Radio\" from any track's context menu\nto generate a radio station based on that song")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Helper Views

    func genreChips(genres: [String], onSelect: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres, id: \.self) { genre in
                    Button(action: {
                        onSelect(genre)
                        HapticManager.light()
                    }) {
                        Text(genre.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.cyberCyan)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberDim)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.cyberCyan)
            }
        }
        .padding(.horizontal, 20)
    }

    func shimmerCards(count: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Theme.cyberDim.opacity(0.15))
                        .frame(width: 120, height: 120)
                        .shimmer()
                }
            }
            .padding(.horizontal, 20)
        }
    }

    func stationsList(_ stations: [RadioStation], title: String) -> some View {
        Group {
            if !stations.isEmpty {
                sectionHeader(title, count: stations.count)
                ForEach(stations) { station in
                    RadioStationRow(station: station) {
                        viewModel.playStation(station)
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    func podcastList(_ shows: [PodcastShow], title: String) -> some View {
        Group {
            if !shows.isEmpty {
                sectionHeader(title, count: shows.count)
                ForEach(shows) { show in
                    PodcastRow(show: show) {
                        showPodcastDetail = show
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

// MARK: - RadioStationCard

struct RadioStationCard: View {
    let station: RadioStation
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                CachedAsyncImage(url: station.faviconURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Theme.cyberSurface
                        Image(systemName: "radio")
                            .font(.system(size: 28))
                            .foregroundColor(Theme.cyberCyan.opacity(0.5))
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

                VStack(spacing: 2) {
                    Text(station.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    if !station.displayCountry.isEmpty {
                        Text(station.displayCountry)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.cyberDim)
                    }
                }
            }
            .frame(width: 120)
        }
    }
}

// MARK: - PodcastCard

struct PodcastCard: View {
    let show: PodcastShow
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                CachedAsyncImage(url: show.artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Theme.cyberSurface
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28))
                            .foregroundColor(Theme.cyberMagenta.opacity(0.5))
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

                VStack(spacing: 2) {
                    Text(show.collectionName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(show.artistName)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.cyberDim)
                        .lineLimit(1)
                }
            }
            .frame(width: 120)
        }
    }
}

// MARK: - SongRadioRow

struct SongRadioRow: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: track.artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Theme.cyberSurface
                }
                .frame(width: 44, height: 44)
                .cornerRadius(CornerRadius.xs)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text(track.durationText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - RadioStationRow

struct RadioStationRow: View {
    let station: RadioStation
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: station.faviconURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Theme.cyberSurface
                        Image(systemName: "radio")
                            .foregroundColor(Theme.cyberCyan.opacity(0.4))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xs))

                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !station.displayCountry.isEmpty {
                            Text(station.displayCountry)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.cyberDim)
                        }
                        if !station.bitrateText.isEmpty {
                            Text("·")
                                .foregroundColor(Theme.cyberDim)
                            Text(station.bitrateText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.cyberDim)
                        }
                    }
                }
                Spacer()
                Circle()
                    .fill(Theme.cyberCyan)
                    .frame(width: 8, height: 8)
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - PodcastRow

struct PodcastRow: View {
    let show: PodcastShow
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: show.artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Theme.cyberSurface
                        Image(systemName: "mic.fill")
                            .foregroundColor(Theme.cyberMagenta.opacity(0.4))
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))

                VStack(alignment: .leading, spacing: 2) {
                    Text(show.collectionName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(show.artistName)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.tertiaryText)
                        .lineLimit(1)
                    if !show.displayGenres.isEmpty {
                        Text(show.displayGenres)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.cyberDim)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.cyberDim)
            }
            .padding(.vertical, 6)
        }
    }
}
