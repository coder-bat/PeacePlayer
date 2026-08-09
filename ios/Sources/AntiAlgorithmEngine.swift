//
//  AntiAlgorithmEngine.swift
//  YTAudioPlayer
//
//  Analyzes listening history and builds exploration sessions
//  targeting the frontier just outside the user's taste bubble.
//

import Foundation
import CoreData
import Combine
import os.log

final class AntiAlgorithmEngine: ObservableObject {
    static let shared = AntiAlgorithmEngine()

    @Published var isExploring = false
    @Published var currentSession: ExplorationSessionSnapshot?
    @Published var explorationQueue: [Track] = []
    @Published var isLoading = false

    private let context: NSManagedObjectContext
    private var cancellables = Set<AnyCancellable>()

    // Taste profile
    private(set) var topArtists: [(name: String, count: Int)] = []
    private(set) var seedTracks: [String] = [] // videoIds

    private init() {
        self.context = PersistenceController.shared.viewContext
    }

    // MARK: - Taste Analysis

    /// Build a taste profile from listening history
    func analyzeListeningHistory() -> (artists: [(String, Int)], seedCount: Int) {
        let request = CDTrack.fetchRequest()
        request.predicate = NSPredicate(format: "playHistory.@count > 0")

        guard let tracks = try? context.fetch(request), !tracks.isEmpty else {
            return ([], 0)
        }

        // Build artist frequency map based on play history count
        var artistCounts: [String: Int] = [:]
        var artistVideoIds: [String: [String]] = [:]

        for track in tracks {
            let artist = track.displayArtist
            let count = track.playHistory?.count ?? 0
            artistCounts[artist, default: 0] += count
            artistVideoIds[artist, default: []].append(track.videoId)
        }

        // S18 / P1-4: weight by SongMemory density. A user with
        // memories on N tracks for an artist is a stronger signal
        // of intent than raw play count — they bothered to write
        // a personal note. Boost such artists so the seed picker
        // reflects a more "intentional" taste profile.
        let memoryRequest = CDSongMemory.fetchRequest()
        let memoryTracks = (try? context.fetch(memoryRequest)) ?? []
        for memory in memoryTracks {
            if let artist = memory.track?.displayArtist {
                // Each memory adds 3 to the play count, capped at +30
                // per artist (so 10 memories on the same artist
                // doesn't drown out real play counts).
                let memoryBonus = min(30, (memoryTracks.filter { $0.track?.displayArtist == artist }.count) * 3)
                artistCounts[artist, default: 0] += memoryBonus
            }
        }

        // Top artists sorted by weighted count
        topArtists = artistCounts.sorted { $0.value > $1.value }
            .prefix(15)
            .map { ($0.key, $0.value) }

        // Pick seed tracks: one from each of top 5 artists (random selection)
        seedTracks = topArtists.prefix(5).compactMap { artist, _ in
            artistVideoIds[artist]?.randomElement()
        }

        return (topArtists, seedTracks.count)
    }

    // MARK: - Frontier Discovery

    /// Fetch tracks just outside the user's comfort zone
    func fetchFrontierTracks(radius: Float = 0.5, completion: @escaping ([Track]) -> Void) {
        if seedTracks.isEmpty {
            let _ = analyzeListeningHistory()
        }
        guard !seedTracks.isEmpty else { completion([]); return }

        isLoading = true

        // Build set of known artists for filtering
        let knownArtists = Set(topArtists.map { $0.0.lowercased() })

        // Fetch radio recommendations for up to 3 seeds
        let seeds = Array(seedTracks.shuffled().prefix(3))
        var allRecommendations: [Track] = []
        let group = DispatchGroup()

        for seedId in seeds {
            group.enter()
            APIService.shared.getRadio(for: seedId)
                .sink(
                    receiveCompletion: { _ in group.leave() },
                    receiveValue: { tracks in
                        allRecommendations.append(contentsOf: tracks)
                    }
                )
                .store(in: &cancellables)
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isLoading = false

            // Filter: remove tracks by known artists
            let frontier = allRecommendations.filter { track in
                let artist = track.displayArtist.lowercased()
                return !knownArtists.contains(artist)
            }

            // Deduplicate by videoId
            var seen = Set<String>()
            let unique = frontier.filter { seen.insert($0.videoId).inserted }

            // Shuffle and limit
            let limited = Array(unique.shuffled().prefix(12))
            completion(limited)
        }
    }

    // MARK: - Session Management

    func startExplorationSession() {
        guard !isExploring else { return }

        // S18 / v1.6.3: os_log breadcrumbs for the v1.6.1 real-device
        // crash where the user tapped "Start Exploring" and the app
        // died. Tag the entire flow so a Console.app or
        // `idevicesyslog` capture can show exactly where the run
        // stopped. The "exploration" category is unique to this
        // engine; filter by category to ignore noise.
        let log = OSLog(subsystem: "com.ytaudioplayer.app", category: "exploration")
        os_log(.info, log: log, "AA: startExplorationSession enter")

        isLoading = true
        let profile = analyzeListeningHistory()
        os_log(.info, log: log, "AA: tasteProfile artists=%d seeds=%d", profile.artists.count, profile.seedCount)

        let radius: Float = lastExplorationRadius()

        fetchFrontierTracks(radius: radius) { [weak self] tracks in
            guard let self = self else {
                os_log(.error, log: log, "AA: self=nil on frontier completion")
                return
            }
            os_log(.info, log: log, "AA: frontier returned %d tracks", tracks.count)
            if tracks.isEmpty {
                self.isLoading = false
                return
            }

            do {
                // S18 / v1.6.3: wrap the CoreData save + view-state
                // mutation in a do-catch. The previous code used
                // `try?` which silently swallowed the error; if the
                // save threw AND the view state was already mutated
                // to a half-built state, a subsequent re-render
                // could trip a crash that's hard to attribute
                // without a stack trace. Now we log + bail.
                let session = CDExplorationSession(context: self.context)
                session.id = UUID()
                session.startedAt = Date()
                session.seedVideoIds = self.seedTracks
                session.explorationRadius = radius
                session.tracksQueued = Int16(tracks.count)
                session.tracksCompleted = 0
                session.tracksSkipped = 0
                session.tracksLiked = 0
                try self.context.save()
                os_log(.info, log: log, "AA: CoreData session saved id=%{public}@", session.id.uuidString)

                self.explorationQueue = tracks
                self.currentSession = ExplorationSessionSnapshot(from: session)
                self.isExploring = true
                self.isLoading = false
            } catch {
                os_log(.error, log: log, "AA: save+publish failed: %{public}@", String(describing: error))
                self.isLoading = false
            }
        }
    }

    func endExplorationSession() {
        isExploring = false
        explorationQueue = []
        currentSession = nil
    }

    // MARK: - Feedback Tracking

    func trackCompleted(videoId: String) {
        guard isExploring, let sessionId = currentSession?.id else { return }
        updateSession(id: sessionId) { session in
            session.tracksCompleted += 1
        }
    }

    func trackSkipped(videoId: String) {
        guard isExploring, let sessionId = currentSession?.id else { return }
        updateSession(id: sessionId) { session in
            session.tracksSkipped += 1
        }
        // Remove from queue
        explorationQueue.removeAll { $0.videoId == videoId }
        if explorationQueue.isEmpty { endExplorationSession() }
    }

    func trackLiked(videoId: String) {
        guard isExploring, let sessionId = currentSession?.id else { return }
        updateSession(id: sessionId) { session in
            session.tracksLiked += 1
        }
    }

    private func updateSession(id: UUID, mutate: (CDExplorationSession) -> Void) {
        let request = CDExplorationSession.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        guard let session = (try? context.fetch(request))?.first else { return }
        mutate(session)
        try? context.save()
        currentSession = ExplorationSessionSnapshot(from: session)
    }

    // MARK: - Stats

    func allSessions() -> [ExplorationSessionSnapshot] {
        let request = CDExplorationSession.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        guard let results = try? context.fetch(request) else { return [] }
        return results.map { ExplorationSessionSnapshot(from: $0) }
    }

    func totalStats() -> (sessions: Int, tracksExplored: Int, liked: Int) {
        let sessions = allSessions()
        let explored = sessions.reduce(0) { $0 + $1.tracksCompleted + $1.tracksSkipped }
        let liked = sessions.reduce(0) { $0 + $1.tracksLiked }
        return (sessions.count, explored, liked)
    }

    private func lastExplorationRadius() -> Float {
        let request = CDExplorationSession.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        request.fetchLimit = 1
        guard let last = (try? context.fetch(request))?.first else { return 0.5 }

        // Adjust: more completions → push further; more skips → pull back
        let rate = last.completionRate
        if rate > 0.7 { return min(1.0, last.explorationRadius + 0.1) }
        if rate < 0.3 { return max(0.1, last.explorationRadius - 0.1) }
        return last.explorationRadius
    }
}

// MARK: - Snapshot

struct ExplorationSessionSnapshot: Identifiable {
    let id: UUID
    let startedAt: Date
    let tracksQueued: Int
    let tracksCompleted: Int
    let tracksSkipped: Int
    let tracksLiked: Int
    let explorationRadius: Float

    var completionRate: Float {
        let total = tracksCompleted + tracksSkipped
        guard total > 0 else { return 0 }
        return Float(tracksCompleted) / Float(total)
    }

    init(from entity: CDExplorationSession) {
        self.id = entity.id
        self.startedAt = entity.startedAt
        self.tracksQueued = Int(entity.tracksQueued)
        self.tracksCompleted = Int(entity.tracksCompleted)
        self.tracksSkipped = Int(entity.tracksSkipped)
        self.tracksLiked = Int(entity.tracksLiked)
        self.explorationRadius = entity.explorationRadius
    }
}
