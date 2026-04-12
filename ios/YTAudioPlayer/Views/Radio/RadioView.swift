import SwiftUI

// MARK: - RadioView

struct RadioView: View {
    @ObservedObject var viewModel: RadioViewModel
    @ObservedObject var library = AudiobookLibrary.shared
    @State private var showPodcastDetail: PodcastShow?
    @State private var selectedAudiobook: Audiobook?

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

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
                    case .audiobooks:
                        audiobookSection
                    case .songRadio:
                        songRadioSection
                    }

                    Spacer(minLength: 100)
                }
                .gesture(DragGesture().onChanged { _ in dismissKeyboard() })
            }
            .overlay(alignment: .top) {
                if let error = viewModel.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.white)
                        Text(error)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Theme.cyberMagenta.opacity(0.9))
                    )
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.3), value: viewModel.errorMessage)
                }
            }
        }
        .task {
            viewModel.loadTopStations()
            viewModel.loadTopPodcasts()
            viewModel.loadTopAudiobooks()
        }
        .sheet(item: $showPodcastDetail) { show in
            PodcastDetailView(show: show, viewModel: viewModel)
        }
        .sheet(item: $selectedAudiobook) { book in
            AudiobookDetailView(book: book, viewModel: viewModel, library: .shared)
        }
    }

    // MARK: - Header

    var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("RADIO")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("stations · podcasts · books · song radio")
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
        ScrollView(.horizontal, showsIndicators: false) {
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
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(viewModel.selectedSection == section ? Theme.cyberCyan : Theme.cyberSurface)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(viewModel.selectedSection == section ? Theme.cyberCyan : Theme.cyberDim.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("\(section.rawValue) section")
                    .accessibilityAddTraits(viewModel.selectedSection == section ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Search Bar

    var searchBar: some View {
        HStack(spacing: 10) {
            if viewModel.isSearching {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Theme.cyberCyan)
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.cyberDim)
            }
            TextField(searchPlaceholder, text: $viewModel.searchText)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white)
                .onSubmit { }
            if !viewModel.searchText.isEmpty {
                Button(action: {
                    viewModel.searchText = ""
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.cyberDim)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
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
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    var searchPlaceholder: String {
        switch viewModel.selectedSection {
        case .stations: return "Search radio stations..."
        case .podcasts: return "Search podcasts..."
        case .audiobooks: return "Search audiobooks..."
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
                if viewModel.genreStations.isEmpty && !viewModel.isLoadingStations {
                    emptySearchState(icon: "antenna.radiowaves.left.and.right", text: "No stations for this genre")
                } else {
                    stationsList(viewModel.genreStations, title: viewModel.selectedGenre.uppercased())
                }
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
                    .overlay(alignment: .trailing) {
                        LinearGradient(
                            colors: [Theme.cyberBackground.opacity(0), Theme.cyberBackground],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 24)
                        .allowsHitTesting(false)
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
                    .overlay(alignment: .trailing) {
                        LinearGradient(
                            colors: [Theme.cyberBackground.opacity(0), Theme.cyberBackground],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 24)
                        .allowsHitTesting(false)
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
            // Song Radio search results
            if !viewModel.searchText.isEmpty && !viewModel.songRadioSearchResults.isEmpty {
                sectionHeader("SEARCH RESULTS", count: viewModel.songRadioSearchResults.count)
                ForEach(viewModel.songRadioSearchResults) { track in
                    SongRadioRow(track: track) {
                        viewModel.startSongRadio(from: track)
                        HapticManager.medium()
                    }
                    .padding(.horizontal, 20)
                }
            } else if !viewModel.searchText.isEmpty && !viewModel.isSearching && viewModel.songRadioSearchResults.isEmpty {
                emptySearchState(icon: "music.note", text: "No tracks found")
            }

            if viewModel.isSearching && viewModel.selectedSection == .songRadio {
                ProgressView()
                    .tint(Theme.cyberCyan)
                    .padding(20)
            }

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
                sectionHeader("RADIO: \(seed.title.uppercased())", count: viewModel.songRadioTracks.count)

                ForEach(viewModel.songRadioTracks) { track in
                    SongRadioRow(track: track) {
                        PlayerState.shared.play(track: track)
                        HapticManager.medium()
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
                            .padding(.vertical, 10)
                            .background(
                                Capsule().stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1.5)
                            )
                    }
                    .accessibilityLabel("Genre: \(genre)")
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
                .lineLimit(1)
                .truncationMode(.tail)
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
            } else if !viewModel.searchText.isEmpty && !viewModel.isSearching {
                emptySearchState(icon: "radio", text: "No stations found")
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
            } else if !viewModel.searchText.isEmpty && !viewModel.isSearching {
                emptySearchState(icon: "mic.fill", text: "No podcasts found")
            }
        }
    }

    private func emptySearchState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(Theme.cyberDim)
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Audiobooks Section

    var audiobookSection: some View {
        LazyVStack(spacing: 20) {
            if !viewModel.searchText.isEmpty {
                if viewModel.isSearching {
                    ProgressView()
                        .tint(Theme.cyberCyan)
                        .padding(20)
                } else if viewModel.audiobookSearchResults.isEmpty {
                    if viewModel.errorMessage != nil {
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 36))
                                .foregroundColor(Theme.cyberDim)
                            Text("SEARCH_FAILED")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.cyberDim)
                            Button {
                                HapticManager.light()
                                viewModel.searchAudiobooks(query: viewModel.searchText)
                            } label: {
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
                    } else {
                        emptySearchState(icon: "book.closed", text: "No audiobooks found")
                    }
                } else {
                    sectionHeader("SEARCH_RESULTS", count: viewModel.audiobookSearchResults.count)
                    ForEach(viewModel.audiobookSearchResults) { book in
                        AudiobookRow(book: book) {
                            selectedAudiobook = book
                        }
                        .padding(.horizontal, 20)
                    }
                }
            } else {
                // My Library section (only when not filtering by genre)
                if !library.books.isEmpty && viewModel.selectedAudiobookGenre.isEmpty {
                    myLibrarySection
                }

                audiobookGenreChips

                if !viewModel.selectedAudiobookGenre.isEmpty {
                    audiobookGrid(books: viewModel.audiobookGenreResults)
                } else {
                    sectionHeader("TOP_AUDIOBOOKS", count: viewModel.topAudiobooks.count)

                    if viewModel.isLoadingAudiobooks && viewModel.topAudiobooks.isEmpty {
                        shimmerCards(count: 5)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(viewModel.topAudiobooks.prefix(10)) { book in
                                    AudiobookCard(book: book) {
                                        selectedAudiobook = book
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .overlay(alignment: .trailing) {
                            LinearGradient(
                                colors: [Theme.cyberBackground.opacity(0), Theme.cyberBackground],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 24)
                            .allowsHitTesting(false)
                        }

                        audiobookGrid(books: Array(viewModel.topAudiobooks.dropFirst(10)))
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var myLibrarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.cyberCyan)
                Text("MY_LIBRARY")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberCyan)
                Text("(\(library.books.count))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
                Spacer()
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(library.books) { libraryBook in
                        LibraryBookCard(libraryBook: libraryBook) {
                            HapticManager.light()
                            selectedAudiobook = libraryBook.audiobook
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .overlay(alignment: .trailing) {
                LinearGradient(
                    colors: [Theme.cyberBackground.opacity(0), Theme.cyberBackground],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 24)
                .allowsHitTesting(false)
            }
        }
    }

    private var audiobookGenreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RadioViewModel.audiobookGenres, id: \.self) { genre in
                    Button {
                        if viewModel.selectedAudiobookGenre == genre {
                            viewModel.selectedAudiobookGenre = ""
                            viewModel.audiobookGenreResults = []
                        } else {
                            viewModel.loadAudiobooksByGenre(genre)
                        }
                        HapticManager.light()
                    } label: {
                        HStack(spacing: 4) {
                            if viewModel.selectedAudiobookGenre == genre && viewModel.isLoadingAudiobooks {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .tint(.black)
                            }
                            Text(genre.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(viewModel.selectedAudiobookGenre == genre ? .black : Theme.cyberCyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(viewModel.selectedAudiobookGenre == genre ? Theme.cyberCyan : Color.clear)
                        )
                        .overlay(Capsule().stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1.5))
                    }
                    .disabled(viewModel.isLoadingAudiobooks)
                    .accessibilityLabel("\(genre) audiobooks")
                    .accessibilityAddTraits(viewModel.selectedAudiobookGenre == genre ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func audiobookGrid(books: [Audiobook]) -> some View {
        Group {
            if viewModel.isLoadingAudiobooks {
                HStack {
                    Spacer()
                    ProgressView().tint(Theme.cyberCyan)
                    Spacer()
                }
                .padding(.top, 40)
            } else if books.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 40))
                        .foregroundColor(Theme.cyberDim)
                    Text("No audiobooks found")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.cyberDim)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(books) { book in
                        AudiobookCard(book: book) {
                            selectedAudiobook = book
                        }
                    }
                }
                .padding(.horizontal, 20)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(station.name), \(station.country)")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(show.collectionName) by \(show.artistName)")
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
                    ZStack {
                        Theme.cyberSurface
                        Image(systemName: "music.note")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.cyberCyan.opacity(0.5))
                    }
                }
                .frame(width: 44, height: 44)
                .cornerRadius(CornerRadius.sm)

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
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title) by \(track.displayArtist)")
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
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))

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
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(station.name), \(station.country), \(station.bitrateText)")
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
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(show.collectionName) by \(show.artistName), \(show.trackCount) episodes")
    }
}

// MARK: - AudiobookCard

struct AudiobookCard: View {
    let book: Audiobook
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: book.coverURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                        .fill(Theme.cyberSurface)
                        .overlay(
                            Image(systemName: "book.closed.fill")
                                .font(.title)
                                .foregroundColor(Theme.cyberDim)
                        )
                }
                .frame(width: 140, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))

                Text(book.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(width: 140, alignment: .leading)

                Text(book.displayAuthors)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title) by \(book.displayAuthors)")
    }
}

// MARK: - LibraryBookCard

struct LibraryBookCard: View {
    let libraryBook: LibraryBook
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Cover art with progress overlay
                ZStack(alignment: .bottom) {
                    CachedAsyncImage(url: libraryBook.audiobook.coverURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: CornerRadius.sm)
                            .fill(Theme.cyberSurface)
                            .overlay(
                                Image(systemName: "book.closed.fill")
                                    .font(.title2)
                                    .foregroundColor(Theme.cyberDim)
                            )
                    }
                    .frame(width: 120, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))

                    // Progress bar at bottom of cover
                    GeometryReader { geo in
                        VStack {
                            Spacer()
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.black.opacity(0.5))
                                    .frame(height: 3)
                                Rectangle()
                                    .fill(libraryBook.isComplete ? Theme.cyberCyan : Theme.cyberMagenta)
                                    .frame(width: geo.size.width * libraryBook.progress, height: 3)
                            }
                        }
                    }
                    .frame(width: 120, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))

                    // Completion badge
                    if libraryBook.isComplete {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                            Text("DONE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.cyberCyan))
                        .padding(.bottom, 8)
                    }
                }

                Text(libraryBook.audiobook.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .leading)

                Text(libraryBook.progressText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(libraryBook.audiobook.title), \(libraryBook.progressText)")
        .accessibilityHint(libraryBook.isComplete ? "Completed" : "Tap to continue reading")
    }
}

// MARK: - AudiobookRow

struct AudiobookRow: View {
    let book: Audiobook
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: book.coverURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: CornerRadius.xs)
                        .fill(Theme.cyberSurface)
                        .overlay(
                            Image(systemName: "book.closed.fill")
                                .font(.caption)
                                .foregroundColor(Theme.cyberDim)
                        )
                }
                .frame(width: 60, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xs))

                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    Text(book.displayAuthors)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.cyberMagenta)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if book.numSections > 0 {
                            Text(book.chapterCountText)
                        }
                        if !book.durationText.isEmpty {
                            Text(book.durationText)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.cyberDim)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title) by \(book.displayAuthors), \(book.chapterCountText)")
    }
}
