import SwiftUI

// MARK: - RadioView

struct RadioView: View {
    // S18 / v1.6.4: was `@ObservedObject var viewModel: RadioViewModel`
    // (passed in from HomeView's destination case). The problem:
    // HomeView observes PlayerState (via `@StateObject`), and any
    // PlayerState change (play, pause, track-end) re-renders HomeView,
    // which re-evaluates the `case .radio: RadioView(viewModel:
    // RadioViewModel())` body — creating a *new* RadioViewModel. The
    // new viewModel starts with empty data; the old data is gone.
    // The user reported "when i play or pause radio, the content in
    // radio view disappears. if i go home and come back to radio
    // view, it comes back again" — that's the .task firing on the
    // new viewModel and reloading.
    //
    // Fix: own the viewModel inside RadioView via @StateObject so it
    // survives parent re-renders. RadioView's viewModel is only used
    // by RadioView itself, so hoisting it is safe.
    @StateObject private var viewModel = RadioViewModel()
    @ObservedObject var library = AudiobookLibrary.shared
    @State private var showPodcastDetail: PodcastShow?
    @State private var selectedAudiobook: Audiobook?
    // S18 / v1.6.1: custom back button dismisses the pushed
    // destination. @Environment(\.dismiss) works for both
    // pushed and presented views, so it pops the parent
    // NavigationStack here.
    @Environment(\.dismiss) private var dismiss

    // Deck design system (docs/design/deck-design-system.md §8 step 6).
    // Drawn on the Deck when the turntable flag is on; each old drawing
    // stays as a `legacy…` twin until the flag retires.
    @ObservedObject private var featureFlags = FeatureFlags.shared
    @FocusState private var searchFocused: Bool
    private var deck: Bool { featureFlags.turntableHome }

    /// What the edge of a scrolling shelf fades into.
    private var wall: Color { deck ? TurntableTokens.room : Theme.cyberBackground }

    /// Something is loading: the deck's amber lamp, or the old spinner.
    @ViewBuilder
    private var busy: some View {
        if deck {
            DeckLamp(color: DeckSignal.power, state: .working, size: 8)
                .accessibilityLabel("Loading")
        } else {
            ProgressView().tint(Theme.cyberCyan)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    var body: some View {
        // S14 (post-hotfix): Radio is pushed INTO Home's
        // NavigationStack — no inner NavigationStack wrapper. (An
        // earlier iteration added one, which crashed on push: iOS
        // does not allow NavigationStack nested inside another
        // NavigationStack.)
        //
        // S18 / v1.6.1: hide the system nav bar. The previous
        // .navigationTitle("Radio") + .navigationBarTitleDisplayMode
        // (.inline) drew a system nav bar with a back chevron AND a
        // "Radio" label, then the custom headerSection below drew
        // its own "RADIO" label. Two competing titles in the same
        // view looked broken; hiding the system bar keeps just the
        // custom chrome. The back chevron is now in the custom
        // header (headerSection).
        ZStack {
            if deck {
                DeckRoom()
            } else {
                Theme.cyberBackground.ignoresSafeArea()
            }

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
                    errorBanner(error)
                        .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.3), value: viewModel.errorMessage)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .environment(\.deckStyle, deck)
        .task {
            viewModel.loadTopStations()
            viewModel.loadTopPodcasts()
            viewModel.loadTopAudiobooks()

            // S18 / v1.6 / P1-5: consume a pending deep-link intent
            // (peaceplayer://podcast/{feedUrl} or
            // peaceplayer://audiobook/{bookId}). ContentView already
            // switched to the Home tab and HomeView already pushed
            // the Radio destination onto its NavigationStack; this
            // is the final hop — open the right detail sheet so the
            // user can pick an episode / chapter.
            //
            // We do this in .task (not .onAppear) so the top-N lists
            // are populating in parallel; the deep-link lookup
            // doesn't depend on them (DeepLinkIndex is the source of
            // truth, not the live @Published arrays).
            let intent = DeepLinkIntent.shared.consume()
            if let show = intent.podcastShow {
                showPodcastDetail = show
            } else if let book = intent.audiobook {
                selectedAudiobook = book
            }
        }
        .sheet(item: $showPodcastDetail) { show in
            PodcastDetailView(show: show, viewModel: viewModel)
        }
        .sheet(item: $selectedAudiobook) { book in
            AudiobookDetailView(book: book, viewModel: viewModel, library: .shared)
        }
    }

    // MARK: - Header

    @ViewBuilder
    var headerSection: some View {
        if deck { deckHeaderSection } else { legacyHeaderSection }
    }

    /// Deck: a metal back button, the name in print, what is inside it
    /// as plain secondary text.
    private var deckHeaderSection: some View {
        HStack(spacing: 4) {
            DeckMetalButton(symbol: "chevron.left", size: 30) {
                HapticManager.light()
                dismiss()
            }
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 3) {
                Text("Radio")
                    .font(DeckType.screenTitle)
                    .foregroundColor(TurntableTokens.cream)
                    .accessibilityAddTraits(.isHeader)
                Text("Stations, podcasts, books, song radio")
                    .font(DeckType.subtitle)
                    .foregroundColor(TurntableTokens.cream.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var legacyHeaderSection: some View {
        HStack(spacing: 12) {
            // S18 / v1.6.1: custom back chevron. Replaces the
            // system back button that came with the system nav
            // bar. Same icon weight and tint as AntiAlgorithmScreen
            // so the destinations share a back-button language.
            Button {
                HapticManager.light()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.cyberCyan)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

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

    @ViewBuilder
    var sectionPicker: some View {
        if deck { deckSectionPicker } else { legacySectionPicker }
    }

    /// Deck: a selector. Chips in an anodised panel, the lamp lit on
    /// the chosen one.
    private var deckSectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(RadioSection.allCases, id: \.self) { section in
                    DeckChip(title: section.rawValue, isSelected: viewModel.selectedSection == section) {
                        withAnimation(DeckMotion.move) {
                            viewModel.selectedSection = section
                            viewModel.searchText = ""
                        }
                        HapticManager.selectionChanged()
                    }
                    .accessibilityLabel("\(section.rawValue) section")
                }
            }
            .padding(5)
        }
        .deckPanel()
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var legacySectionPicker: some View {
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

    @ViewBuilder
    var searchBar: some View {
        if deck { deckSearchBar } else { legacySearchBar }
    }

    /// Deck: the text lies in a well, lit while it has focus.
    private var deckSearchBar: some View {
        HStack(spacing: 10) {
            if viewModel.isSearching {
                DeckLamp(color: DeckSignal.power, state: .working, size: 6)
                    .frame(width: 18)
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.7))
                    .frame(width: 18)
            }
            TextField("", text: $viewModel.searchText,
                      prompt: Text(searchPlaceholder).foregroundColor(TurntableTokens.cream.opacity(0.4)))
                .font(DeckType.body)
                .foregroundColor(TurntableTokens.cream)
                .tint(DeckSignal.live)
                .focused($searchFocused)
                .submitLabel(.search)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                        .frame(width: 34, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, viewModel.searchText.isEmpty ? 18 : 6)
        .frame(height: 48)
        .deckWell(Capsule(), lit: searchFocused ? DeckSignal.live : nil)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.2), value: searchFocused)
    }

    private var legacySearchBar: some View {
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
            genreChips(genres: RadioViewModel.radioGenres, selected: viewModel.selectedGenre) { genre in
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
                            colors: [wall.opacity(0), wall],
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
                            colors: [wall.opacity(0), wall],
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
                busy
                    .padding(20)
            }

            if !viewModel.recentSongRadios.isEmpty {
                sectionHeader("RECENT_RADIOS", count: viewModel.recentSongRadios.count)

                ForEach(viewModel.recentSongRadios) { track in
                    if deck {
                        Button {
                            viewModel.startSongRadio(from: track)
                        } label: {
                            DeckTrackRow(
                                title: track.title,
                                subtitle: "Radio based on \(track.displayArtist)",
                                artworkURL: track.artworkURL
                            ) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(TurntableTokens.aluminium.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                        .deckRowRule()
                        .padding(.horizontal, 16)
                    } else {
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
            }

            if viewModel.isLoadingSongRadio {
                busy
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
            } else if deck {
                VStack(spacing: 8) {
                    Text("Start song radio")
                        .font(DeckType.title)
                        .foregroundColor(TurntableTokens.cream)
                    Text("Choose Start Radio from any song's menu and the deck will build a station from it.")
                        .font(DeckType.subtitle)
                        .foregroundColor(TurntableTokens.cream.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40)
                .padding(.top, 60)
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

    @ViewBuilder
    func genreChips(genres: [String], selected: String = "", onSelect: @escaping (String) -> Void) -> some View {
        if deck {
            // Deck: a second selector under the first. (A tuner dial
            // for genres is still to come; see the design doc.)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(genres, id: \.self) { genre in
                        DeckChip(title: genre, isSelected: genre == selected) {
                            onSelect(genre)
                            HapticManager.selectionChanged()
                        }
                        .accessibilityLabel("Genre: \(genre)")
                    }
                }
                .padding(5)
            }
            .deckPanel()
            .padding(.horizontal, 16)
        } else {
            legacyGenreChips(genres: genres, onSelect: onSelect)
        }
    }

    func legacyGenreChips(genres: [String], onSelect: @escaping (String) -> Void) -> some View {
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

    @ViewBuilder
    func sectionHeader(_ title: String, count: Int) -> some View {
        if deck {
            // Deck: a ledge. "TOP_STATIONS" becomes "Top stations".
            let words = title.replacingOccurrences(of: "_", with: " ").lowercased()
            DeckLedge(title: words.prefix(1).uppercased() + words.dropFirst(), count: count > 0 ? count : nil)
                .padding(.horizontal, 16)
        } else {
            legacySectionHeader(title, count: count)
        }
    }

    func legacySectionHeader(_ title: String, count: Int) -> some View {
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
                    if deck {
                        TurntableTokens.walnut.opacity(0.5)
                            .frame(width: 120, height: 120)
                            .deckCover(cornerRadius: 3)
                            .shimmer()
                    } else {
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(Theme.cyberDim.opacity(0.15))
                            .frame(width: 120, height: 120)
                            .shimmer()
                    }
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

    @ViewBuilder
    private func emptySearchState(icon: String, text: String) -> some View {
        if deck {
            // Deck: one quiet line, no icon in a box.
            Text(text)
                .font(DeckType.title)
                .foregroundColor(TurntableTokens.cream.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
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
    }

    private func errorBanner(_ message: String) -> some View {
        Group {
            if deck {
                HStack(spacing: 10) {
                    DeckLamp(color: DeckSignal.attention, state: .lit, size: 6)
                    Text(message)
                        .font(DeckType.subtitle)
                        .foregroundColor(TurntableTokens.cream)
                        .lineLimit(2)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .deckPanel(cornerRadius: CornerRadius.md)
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.white)
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Theme.cyberMagenta.opacity(0.9))
                )
            }
        }
    }

    // MARK: - Audiobooks Section

    var audiobookSection: some View {
        LazyVStack(spacing: 20) {
            if !viewModel.searchText.isEmpty {
                if viewModel.isSearching {
                    busy
                        .padding(20)
                } else if viewModel.audiobookSearchResults.isEmpty {
                    if viewModel.errorMessage != nil && deck {
                        VStack(spacing: 14) {
                            Text("Search failed")
                                .font(DeckType.title)
                                .foregroundColor(TurntableTokens.cream)
                            DeckButton(title: "Retry", symbol: "arrow.clockwise", kind: .card) {
                                HapticManager.light()
                                viewModel.searchAudiobooks(query: viewModel.searchText)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else if viewModel.errorMessage != nil {
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
                                colors: [wall.opacity(0), wall],
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
            if deck {
                DeckLedge(title: "My library", count: library.books.count)
                    .padding(.horizontal, 16)
            } else {
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
            }

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
                    colors: [wall.opacity(0), wall],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 24)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var audiobookGenreChips: some View {
        if deck {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(RadioViewModel.audiobookGenres, id: \.self) { genre in
                        DeckChip(title: genre, isSelected: viewModel.selectedAudiobookGenre == genre) {
                            if viewModel.selectedAudiobookGenre == genre {
                                viewModel.selectedAudiobookGenre = ""
                                viewModel.audiobookGenreResults = []
                            } else {
                                viewModel.loadAudiobooksByGenre(genre)
                            }
                            HapticManager.selectionChanged()
                        }
                        .disabled(viewModel.isLoadingAudiobooks)
                        .accessibilityLabel("\(genre) audiobooks")
                    }
                }
                .padding(5)
            }
            .deckPanel()
            .padding(.horizontal, 16)
        } else {
            legacyAudiobookGenreChips
        }
    }

    private var legacyAudiobookGenreChips: some View {
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
                    busy
                    Spacer()
                }
                .padding(.top, 40)
            } else if books.isEmpty && deck {
                emptySearchState(icon: "book.closed", text: "No audiobooks found")
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

// MARK: - Deck helpers

private extension View {
    /// The hairline under a Deck row.
    func deckRowRule() -> some View {
        overlay(alignment: .bottom) {
            Rectangle().fill(TurntableTokens.cream.opacity(0.08)).frame(height: 1)
        }
    }
}

/// A shelf item in the Deck: a sleeve, then its name in print and a
/// line of small print under it.
private struct DeckShelfCard: View {
    let artworkURL: URL?
    let symbol: String
    let title: String
    let detail: String
    var width: CGFloat = 120
    var height: CGFloat = 120
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        TurntableTokens.walnut
                        Image(systemName: symbol)
                            .font(.system(size: 26, weight: .light))
                            .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                    }
                }
                .frame(width: width, height: height)
                .deckCover(cornerRadius: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(TurntableTokens.cream)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundColor(TurntableTokens.cream.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(DeckPressStyle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - RadioStationCard

struct RadioStationCard: View {
    let station: RadioStation
    let onTap: () -> Void

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            DeckShelfCard(artworkURL: station.faviconURL, symbol: "radio", title: station.name,
                          detail: station.displayCountry, onTap: onTap)
                .accessibilityLabel("\(station.name), \(station.country)")
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
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

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            DeckShelfCard(artworkURL: show.artworkURL, symbol: "mic.fill", title: show.collectionName,
                          detail: show.artistName, onTap: onTap)
                .accessibilityLabel("\(show.collectionName) by \(show.artistName)")
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
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

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            Button(action: onTap) {
                DeckTrackRow(
                    title: track.title,
                    subtitle: track.displayArtist,
                    artworkURL: track.artworkURL,
                    smallPrint: DeckFormat.runtime(track.durationSeconds)
                )
            }
            .buttonStyle(.plain)
            .deckRowRule()
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        TrackRow(
            title: track.title,
            subtitle: track.displayArtist,
            artworkURL: track.artworkURL,
            titleSize: 15,
            subtitleSize: 13,
            accessory: .custom(AnyView(
                Text(track.durationText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            )),
            onTap: onTap
        )
    }
}

// MARK: - RadioStationRow

struct RadioStationRow: View {
    let station: RadioStation
    let onTap: () -> Void

    private var subtitleText: String {
        var parts: [String] = []
        if !station.displayCountry.isEmpty { parts.append(station.displayCountry) }
        if !station.bitrateText.isEmpty { parts.append(station.bitrateText) }
        return parts.joined(separator: " · ")
    }

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            Button(action: onTap) {
                DeckTrackRow(title: station.name, subtitle: subtitleText, artworkURL: station.faviconURL)
            }
            .buttonStyle(.plain)
            .deckRowRule()
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        TrackRow(
            title: station.name,
            subtitle: subtitleText,
            artworkURL: station.faviconURL,
            titleSize: 15,
            subtitleSize: 12,
            accessory: .dotIndicator(color: Theme.cyberCyan),
            onTap: onTap
        )
    }
}

// MARK: - PodcastRow

struct PodcastRow: View {
    let show: PodcastShow
    let onTap: () -> Void

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            Button(action: onTap) {
                DeckTrackRow(title: show.collectionName, subtitle: show.artistName, artworkURL: show.artworkURL) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(TurntableTokens.aluminium.opacity(0.7))
                }
            }
            .buttonStyle(.plain)
            .deckRowRule()
            .accessibilityLabel("\(show.collectionName) by \(show.artistName), \(show.trackCount) episodes")
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
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

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            DeckShelfCard(artworkURL: book.coverURL, symbol: "book.closed.fill", title: book.title,
                          detail: book.displayAuthors, width: 140, height: 180, onTap: onTap)
                .accessibilityLabel("\(book.title) by \(book.displayAuthors)")
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
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

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: the cover with a progress channel along its foot. Brass
    /// while reading; a lit lamp and "DONE" when finished.
    private var deckBody: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: libraryBook.audiobook.coverURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        TurntableTokens.walnut
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 22, weight: .light))
                            .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                    }
                }
                .frame(width: 120, height: 160)
                .deckCover(cornerRadius: 3)
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(TurntableTokens.brass)
                            .frame(width: max(3, geo.size.width * libraryBook.progress), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(libraryBook.audiobook.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(TurntableTokens.cream)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        if libraryBook.isComplete {
                            DeckLamp(color: DeckSignal.power, state: .lit, size: 4.5)
                        }
                        Text(libraryBook.isComplete ? "DONE" : libraryBook.progressText.uppercased())
                            .font(DeckType.engraved)
                            .foregroundColor(TurntableTokens.brass)
                            .lineLimit(1)
                    }
                }
                .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(DeckPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(libraryBook.audiobook.title), \(libraryBook.progressText)")
        .accessibilityHint(libraryBook.isComplete ? "Completed" : "Tap to continue reading")
    }

    private var legacyBody: some View {
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

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            Button(action: onTap) {
                DeckTrackRow(
                    title: book.title,
                    subtitle: book.numSections > 0 ? "\(book.displayAuthors) · \(book.chapterCountText)" : book.displayAuthors,
                    artworkURL: book.coverURL,
                    smallPrint: book.durationText.isEmpty ? nil : book.durationText.uppercased()
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(TurntableTokens.aluminium.opacity(0.7))
                }
            }
            .buttonStyle(.plain)
            .deckRowRule()
            .accessibilityLabel("\(book.title) by \(book.displayAuthors), \(book.chapterCountText)")
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
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
