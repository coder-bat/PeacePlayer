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
    @Published var songRadioTracks: [Track] = []
    @Published var songRadioSeed: Track?
    @Published var isLoadingSongRadio = false
    @Published var recentSongRadios: [Track] = []
    
    // Podcast episodes (for detail view)
    @Published var currentEpisodes: [PodcastEpisode] = []
    @Published var isLoadingEpisodes = false
    
    private var cancellables = Set<AnyCancellable>()
    private var searchCancellable: AnyCancellable?
    
    static let radioGenres = ["lofi", "jazz", "classical", "electronic", "ambient", "hiphop", "rock", "pop", "news", "chill"]
    static let podcastGenres = ["Comedy", "Technology", "True Crime", "News", "Education", "Science", "Music", "Business", "Health", "Sports"]
    
    init() {
        loadRecentSongRadios()
        setupSearchDebounce()
    }
    
    private func setupSearchDebounce() {
        $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                guard let self = self, !query.isEmpty else { return }
                switch self.selectedSection {
                case .stations:
                    self.searchStations(query: query)
                case .podcasts:
                    self.searchPodcasts(query: query)
                case .songRadio:
                    break
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Radio Stations
    
    func loadTopStations() {
        guard topStations.isEmpty else { return }
        isLoadingStations = true
        APIService.shared.getTopRadioStations(limit: 30)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingStations = false
                if case .failure(let error) = completion {
                    print("⚠️ [RadioVM] Top stations failed: \(error.localizedDescription)")
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
                if case .failure(let error) = completion {
                    print("⚠️ [RadioVM] Genre stations failed: \(error.localizedDescription)")
                }
            }, receiveValue: { [weak self] stations in
                self?.genreStations = stations
            })
            .store(in: &cancellables)
    }
    
    func searchStations(query: String) {
        isLoadingStations = true
        APIService.shared.searchRadioStations(query: query, limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingStations = false
                if case .failure(let error) = completion {
                    print("⚠️ [RadioVM] Station search failed: \(error.localizedDescription)")
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
        guard topPodcasts.isEmpty else { return }
        isLoadingPodcasts = true
        APIService.shared.getTopPodcasts(limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingPodcasts = false
                if case .failure(let error) = completion {
                    print("⚠️ [RadioVM] Top podcasts failed: \(error.localizedDescription)")
                }
            }, receiveValue: { [weak self] shows in
                self?.topPodcasts = shows
            })
            .store(in: &cancellables)
    }
    
    func searchPodcasts(query: String) {
        isLoadingPodcasts = true
        APIService.shared.searchPodcasts(query: query, limit: 20)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingPodcasts = false
                if case .failure(let error) = completion {
                    print("⚠️ [RadioVM] Podcast search failed: \(error.localizedDescription)")
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
                if case .failure(let error) = completion {
                    print("⚠️ [RadioVM] Episodes failed: \(error.localizedDescription)")
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
    
    // MARK: - Song Radio
    
    func startSongRadio(from track: Track) {
        songRadioSeed = track
        isLoadingSongRadio = true
        songRadioTracks = []
        
        APIService.shared.getRadio(for: track.videoId)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoadingSongRadio = false
                if case .failure(let error) = completion {
                    print("⚠️ [RadioVM] Song radio failed: \(error.localizedDescription)")
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
