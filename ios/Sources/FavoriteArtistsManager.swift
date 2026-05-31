//
//  FavoriteArtistsManager.swift
// YTAudioPlayer
//
//  Manages favorite artists for personalized home suggestions
//

import Foundation
import Combine

/// Manages favorite artists with UserDefaults persistence
class FavoriteArtistsManager: ObservableObject {
    static let shared = FavoriteArtistsManager()

    // MARK: - Published Properties

    @Published var artists: [String] = []

    // MARK: - Private Properties

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let favoriteArtists = "user.favoriteArtists"
    }

    // MARK: - Initialization

    private init() {
        loadArtists()
    }

    // MARK: - Public API

    var isEmpty: Bool {
        artists.isEmpty
    }

    func getArtists() -> [String] {
        artists
    }

    func addArtist(_ artist: String) {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !artists.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { return }
        artists.append(trimmed)
        saveArtists()
    }

    func removeArtist(_ artist: String) {
        artists.removeAll { $0 == artist }
        saveArtists()
    }

    func removeArtist(at offsets: IndexSet) {
        artists.remove(atOffsets: offsets)
        saveArtists()
    }

    // MARK: - Persistence

    private func loadArtists() {
        if let data = defaults.data(forKey: Keys.favoriteArtists),
           let loaded = try? JSONDecoder().decode([String].self, from: data) {
            artists = loaded
        }
    }

    private func saveArtists() {
        if let data = try? JSONEncoder().encode(artists) {
            defaults.set(data, forKey: Keys.favoriteArtists)
        }
    }
}