//
//  RadioViewModel.swift
//  YTAudioPlayer
//
//  ViewModel for Radio, Podcasts, and Song Radio sections
//

import SwiftUI
import Combine

enum RadioSection: String, CaseIterable {
    case stations = "Stations"
    case podcasts = "Podcasts"
    case audiobooks = "Books"
    case songRadio = "Song Radio"
}

class RadioViewModel: ObservableObject {
    // Section selection
    @Published var selectedSection: RadioSection = .stations
    @Published var searchText: String = ""
    
    // Radio stations
    @Published var topStations: [RadioStation] = []
    @Published var genreStations: [RadioStation] = []
    @Published var stationSearchResults: [RadioStation] = []
    @Published var selectedGenre: String = ""
    @Published var isLoadingStations = false
    
    // Podcasts
    @Published var topPodcasts: [PodcastShow] = []
    @Published var podcastSearchResults: [PodcastShow] = []
    @Published var isLoadingPodcasts = false
    
    // Song Radio
    @Published var songRadioSearchResults: [Track] = []
    @Published var songRadioTracks: [Track] = []
    @Published var songRadioSeed: Track?
    @Published var isLoadingSongRadio = false
    @Published var recentSongRadios: [Track] = []
    
    // Audiobooks
    @Published var topAudiobooks: [Audiobook] = []
    @Published var audiobookSearchResults: [Audiobook] = []
    @Published var audiobookGenreResults: [Audiobook] = []
    @Published var selectedAudiobookGenre: String = ""
    @Published var isLoadingAudiobooks = false
    
    // Audiobook chapters (for detail view)
    @Published var currentChapters: [AudiobookChapter] = []
    @Published var currentChaptersCoverUrl: String = ""
    @Published var isLoadingChapters = false
    
    // Podcast episodes (for detail view)
    @Published var currentEpisodes: [PodcastEpisode] = []
    @Published var isLoadingEpisodes = false
    
    @Published var errorMessage: String?
    @Published var isSearching = false
    
    private var cancellables = Set<AnyCancellable>()
    private var searchCancellable: AnyCancellable?
    
    static let radioGenres = ["lofi", "jazz", "classical", "electronic", "ambient", "hiphop", "rock", "pop", "news", "chill"]
    static let podcastGenres = ["Comedy", "Technology", "True Crime", "News", "Education", "Science", "Music", "Business", "Health", "Sports"]
    static let audiobookGenres = ["Fiction", "Science Fiction", "Mystery", "Romance", "Fantasy", "History", "Philosophy", "Poetry", "Biography", "Children"]
    
    init() {
        loadRecentSongRadios()
        setupSearchDebounce()
    }
    
    private func setupSearchDebounce() {
        searchCancellable = $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                guard let self = self else { return }
                guard !query.isEmpty else {
                    self.songRadioSearchResults = []
                    self.stationSearchResults = []
                    self.podcastSearchResults = []
                    self.audiobookSearchResults = []
                    return
                }
                switch self.selectedSection {
                case .stations:
                    self.searchStations(query: query)
                case .podcasts:
                    self.searchPodcasts(query: query)
                case .audiobooks:
                    self.searchAudiobooks(query: query)
                case .songRadio:
                    self.searchSongRadio(query: query)
                }
            }
    }
    
    // MARK: - Radio Stations
    
    func loadTopStations() {
        // Remove lazy loading guard - always refresh to ensure data is fresh
        // guard topStations.isEmpty else { return }
        isLoadingStations = true
        APIService.shared.getTopRadioStations(limit: 30)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingStations = false
                if case .failure = completion {
                    self?.setError("Failed to load stations")
                }
            }, receiveValue: { [weak self] stations in
                self?.topStations = stations
            })
            .store(in: &cancellables)
    }
    
    func loadStationsByGenre(_ genre: String) {
        selectedGenre = genre
        isLoadingStations = true
        APIService.shared.getRadioStationsByGenre(tag: genre, limit: 30)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingStations = false
                if case .failure = completion {
                    self?.setError("Failed to load genre stations")
                }
            }, receiveValue: { [weak self] stations in
                self?.genreStations = stations
            })
            .store(in: &cancellables)
    }
    
    func searchStations(query: String) {
        isLoadingStations = true
        isSearching = true
        APIService.shared.searchRadioStations(query: query, limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingStations = false
                self?.isSearching = false
                if case .failure = completion {
                    self?.setError("Search failed")
                }
            }, receiveValue: { [weak self] stations in
                self?.stationSearchResults = stations
            })
            .store(in: &cancellables)
    }
    
    func playStation(_ station: RadioStation) {
        PlayerState.shared.playRadioStation(station)
        HapticManager.medium()
        APIService.shared.registerRadioClick(stationuuid: station.stationuuid)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &cancellables)
    }
    
    // MARK: - Podcasts
    
    func loadTopPodcasts() {
        // Remove lazy loading guard - always refresh to ensure data is fresh
        // guard topPodcasts.isEmpty else { return }
        isLoadingPodcasts = true
        APIService.shared.getTopPodcasts(limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingPodcasts = false
                if case .failure = completion {
                    self?.setError("Failed to load podcasts")
                }
            }, receiveValue: { [weak self] shows in
                self?.topPodcasts = shows
            })
            .store(in: &cancellables)
    }
    
    func searchPodcasts(query: String) {
        isLoadingPodcasts = true
        isSearching = true
        APIService.shared.searchPodcasts(query: query, limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingPodcasts = false
                self?.isSearching = false
                if case .failure = completion {
                    self?.setError("Search failed")
                }
            }, receiveValue: { [weak self] shows in
                self?.podcastSearchResults = shows
            })
            .store(in: &cancellables)
    }
    
    func loadEpisodes(for show: PodcastShow) {
        isLoadingEpisodes = true
        currentEpisodes = []
        APIService.shared.getPodcastEpisodes(feedUrl: show.feedUrl, limit: 50)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingEpisodes = false
                if case .failure = completion {
                    self?.setError("Failed to load episodes")
                }
            }, receiveValue: { [weak self] episodes in
                self?.currentEpisodes = episodes
            })
            .store(in: &cancellables)
    }
    
    func playEpisode(_ episode: PodcastEpisode) {
        PlayerState.shared.playPodcastEpisode(episode)
        HapticManager.medium()
    }
    
    // MARK: - Audiobooks
    
    func loadTopAudiobooks() {
        // Remove lazy loading guard - always refresh to ensure data is fresh
        // guard topAudiobooks.isEmpty else { return }
        isLoadingAudiobooks = true
        APIService.shared.getTopAudiobooks(limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingAudiobooks = false
                if case .failure = completion {
                    self?.setError("Failed to load audiobooks")
                }
            }, receiveValue: { [weak self] books in
                self?.topAudiobooks = books
            })
            .store(in: &cancellables)
    }
    
    func searchAudiobooks(query: String) {
        isLoadingAudiobooks = true
        isSearching = true
        APIService.shared.searchAudiobooks(query: query, limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingAudiobooks = false
                self?.isSearching = false
                if case .failure = completion {
                    self?.setError("Search failed")
                }
            }, receiveValue: { [weak self] books in
                self?.audiobookSearchResults = books
            })
            .store(in: &cancellables)
    }
    
    func loadAudiobooksByGenre(_ genre: String) {
        selectedAudiobookGenre = genre
        audiobookGenreResults = []
        isLoadingAudiobooks = true
        APIService.shared.getAudiobooksByGenre(genre: genre, limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingAudiobooks = false
                if case .failure = completion {
                    self?.setError("Failed to load genre audiobooks")
                }
            }, receiveValue: { [weak self] books in
                self?.audiobookGenreResults = books
            })
            .store(in: &cancellables)
    }
    
    func loadChapters(for book: Audiobook) {
        isLoadingChapters = true
        currentChapters = []
        currentChaptersCoverUrl = ""
        let rssUrl = book.rssUrl.isEmpty ? nil : book.rssUrl
        APIService.shared.getAudiobookChapters(bookId: book.id, rssUrl: rssUrl)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingChapters = false
                if case .failure = completion {
                    self?.setError("Failed to load chapters")
                }
            }, receiveValue: { [weak self] response in
                self?.currentChapters = response.chapters
                self?.currentChaptersCoverUrl = response.coverUrl
            })
            .store(in: &cancellables)
    }
    
    func playChapter(_ chapter: AudiobookChapter, from book: Audiobook) {
        PlayerState.shared.playAudiobookChapter(chapter, chapters: currentChapters, bookTitle: book.title, bookId: book.id)
        HapticManager.medium()
    }
    
    // MARK: - Song Radio
    
    private func searchSongRadio(query: String) {
        isSearching = true
        songRadioSearchResults = []
        
        APIService.shared.search(query: query, limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isSearching = false
                if case .failure = completion {
                    self?.setError("Search failed")
                }
            }, receiveValue: { [weak self] tracks in
                self?.songRadioSearchResults = tracks
            })
            .store(in: &cancellables)
    }
    
    func startSongRadio(from track: Track) {
        songRadioSeed = track
        isLoadingSongRadio = true
        songRadioTracks = []
        
        APIService.shared.getRadio(for: track.videoId)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingSongRadio = false
                if case .failure = completion {
                    self?.setError("Failed to start radio")
                }
            }, receiveValue: { [weak self] tracks in
                guard let self = self else { return }
                self.songRadioTracks = tracks
                
                if let first = tracks.first {
                    PlayerState.shared.play(track: first)
                }
                
                self.saveToRecentSongRadios(track)
            })
            .store(in: &cancellables)
    }
    
    // MARK: - Search Control
    
    func cancelSearch() {
        searchCancellable?.cancel()
        searchCancellable = nil
        isSearching = false
        setupSearchDebounce()
    }
    
    private func setError(_ message: String) {
        errorMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.errorMessage == message { self?.errorMessage = nil }
        }
    }
    
    // MARK: - Persistence
    
    private func saveToRecentSongRadios(_ track: Track) {
        var recents = recentSongRadios.filter { $0.videoId != track.videoId }
        recents.insert(track, at: 0)
        recentSongRadios = Array(recents.prefix(5))
        
        if let data = try? JSONEncoder().encode(recentSongRadios) {
            UserDefaults.standard.set(data, forKey: "recentSongRadios")
        }
    }
    
    private func loadRecentSongRadios() {
        guard let data = UserDefaults.standard.data(forKey: "recentSongRadios"),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else { return }
        recentSongRadios = tracks
    }
}
