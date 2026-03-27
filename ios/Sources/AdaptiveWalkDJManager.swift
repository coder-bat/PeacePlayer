//
//  AdaptiveWalkDJManager.swift
//  YTAudioPlayer
//
//  Walking-aware song suggestions that hand off into the existing playback flow
//

import Foundation
import Combine
import CoreData
import CoreMotion
import UserNotifications

struct WalkDJSuggestion: Codable {
    let videoId: String
    let title: String
    let artist: String
    let reason: String
    let createdAt: Date
}

private struct WalkDJCandidate {
    let track: Track
    var score: Double
    var flags: Set<Flag>

    enum Flag: Hashable {
        case downloaded
        case liked
        case recent
        case timeOfDay
        case memory
    }
}

final class AdaptiveWalkDJManager: ObservableObject {
    static let shared = AdaptiveWalkDJManager()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var statusText = "Adaptive Walk DJ is off."
    @Published private(set) var lastSuggestionSummary: String?

    private let defaults = UserDefaults.standard
    private let persistence = PersistenceController.shared
    private let dataManager = DataManager.shared
    private let motionManager = CMMotionActivityManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.ytaudio.walkdj.motion"
        queue.qualityOfService = .utility
        return queue
    }()

    private var isMonitoringMotion = false

    private enum Keys {
        static let isEnabled = "walkDJ.isEnabled"
        static let lastSuggestedAt = "walkDJ.lastSuggestedAt"
        static let lastSuggestedVideoId = "walkDJ.lastSuggestedVideoId"
        static let pendingSuggestion = "walkDJ.pendingSuggestion"
    }

    private enum Constants {
        static let notificationIdentifier = "adaptive-walk-dj-suggestion"
        static let deepLinkKey = "walkDJDeepLink"
        static let suggestionCooldown: TimeInterval = 30 * 60
    }

    private init() {
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        lastSuggestionSummary = pendingSuggestion?.title
        refreshStatusText()
    }

    func configure() {
        refreshStatusText()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.isEnabled)
        isEnabled = enabled

        if enabled {
            requestPermissionsIfNeeded()
            startMonitoringIfPossible()
        } else {
            stopMonitoring()
            clearPendingSuggestion()
        }

        refreshStatusText()
    }

    func handleScenePhaseChange(isActive: Bool) {
        if isActive {
            refreshStatusText()
            if isEnabled {
                requestPermissionsIfNeeded()
                startMonitoringIfPossible()
            }
        } else {
            stopMonitoring()
        }
    }

    func triggerTestSuggestion() {
        requestPermissionsIfNeeded()

        guard isEnabled else {
            statusText = "Enable Adaptive Walk DJ to test it."
            return
        }

        guard let suggestion = selectSuggestion() else {
            statusText = "No personal walk-fit song is ready yet."
            return
        }

        scheduleNotification(for: suggestion)
        statusText = "Test walk suggestion queued."
    }

    func handleWalkDJURL(_ url: URL) {
        guard url.scheme == "peaceplayer", url.host == "walk-dj" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let videoId = components?.queryItems?.first(where: { $0.name == "videoId" })?.value else { return }

        playSuggestedTrack(videoId: videoId)
    }

    func handleNotificationResponse(userInfo: [AnyHashable: Any]) {
        if let deepLink = userInfo[Constants.deepLinkKey] as? String, let url = URL(string: deepLink) {
            handleWalkDJURL(url)
            return
        }

        if let videoId = userInfo["videoId"] as? String {
            playSuggestedTrack(videoId: videoId)
        }
    }

    private func requestPermissionsIfNeeded() {
        requestNotificationAuthorization()
        requestMotionAuthorizationIfNeeded()
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshStatusText()
            }
        }
    }

    private func requestMotionAuthorizationIfNeeded() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            refreshStatusText()
            return
        }

        guard CMMotionActivityManager.authorizationStatus() == .notDetermined else {
            refreshStatusText()
            return
        }

        motionManager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: motionQueue) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshStatusText()
            }
        }
    }

    private func startMonitoringIfPossible() {
        guard isEnabled else { return }
        guard CMMotionActivityManager.isActivityAvailable() else {
            statusText = "Walking detection is unavailable on this device."
            return
        }

        let status = CMMotionActivityManager.authorizationStatus()
        guard status == .authorized || status == .notDetermined else {
            refreshStatusText()
            return
        }

        guard !isMonitoringMotion else { return }
        isMonitoringMotion = true

        motionManager.startActivityUpdates(to: motionQueue) { [weak self] activity in
            guard let self, let activity else { return }
            self.handleActivity(activity)
        }

        refreshStatusText()
    }

    private func stopMonitoring() {
        guard isMonitoringMotion else { return }
        motionManager.stopActivityUpdates()
        isMonitoringMotion = false
    }

    private func handleActivity(_ activity: CMMotionActivity) {
        guard activity.walking else { return }
        guard activity.confidence != .low else { return }

        DispatchQueue.main.async { [weak self] in
            self?.maybeSuggestForWalking()
        }
    }

    private func maybeSuggestForWalking() {
        guard isEnabled else { return }
        guard playbackIsInactive else {
            statusText = "Walk DJ is waiting until playback stops."
            return
        }

        guard cooldownAllowsSuggestion else {
            statusText = "Walk DJ cooldown active."
            return
        }

        guard let suggestion = selectSuggestion() else {
            statusText = "No walk-fit suggestion available yet."
            return
        }

        scheduleNotification(for: suggestion)
        statusText = "Walk suggestion ready."
    }

    private var playbackIsInactive: Bool {
        let state = PlayerState.shared.playbackState
        return !state.isPlaying && !state.isLoading && state != .paused
    }

    private var cooldownAllowsSuggestion: Bool {
        guard let lastSuggestedAt = defaults.object(forKey: Keys.lastSuggestedAt) as? Date else { return true }
        return Date().timeIntervalSince(lastSuggestedAt) >= Constants.suggestionCooldown
    }

    private func scheduleNotification(for suggestion: WalkDJSuggestion) {
        let content = UNMutableNotificationContent()
        content.title = "Adaptive Walk DJ"
        content.subtitle = "\(suggestion.title) — \(suggestion.artist)"
        content.body = suggestion.reason
        content.sound = .default
        content.userInfo = [
            "videoId": suggestion.videoId,
            Constants.deepLinkKey: "peaceplayer://walk-dj?videoId=\(suggestion.videoId)"
        ]

        let request = UNNotificationRequest(
            identifier: Constants.notificationIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Constants.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Constants.notificationIdentifier])
        center.add(request)

        let encoded = try? JSONEncoder().encode(suggestion)
        defaults.set(Date(), forKey: Keys.lastSuggestedAt)
        defaults.set(suggestion.videoId, forKey: Keys.lastSuggestedVideoId)
        defaults.set(encoded, forKey: Keys.pendingSuggestion)
        lastSuggestionSummary = "\(suggestion.title) — \(suggestion.reason)"
    }

    private func playSuggestedTrack(videoId: String) {
        guard let track = resolveTrack(videoId: videoId) ?? pendingSuggestionTrack(videoId: videoId) else {
            statusText = "Walk DJ couldn’t load that suggestion."
            clearPendingSuggestion()
            return
        }

        TrackStore.shared.saveTrack(track)
        QueuePrefetcher.shared.resetPrefetchState()
        PlayerState.shared.queue.removeAll()
        PlayerState.shared.currentIndex = 0
        PlayerState.shared.play(track: track)
        PlayerState.shared.showFullPlayer = true
        HapticManager.success()

        clearPendingSuggestion()
        statusText = "Started Walk DJ suggestion."
    }

    private func clearPendingSuggestion() {
        defaults.removeObject(forKey: Keys.pendingSuggestion)
    }

    private func resolveTrack(videoId: String) -> Track? {
        if let cached = TrackStore.shared.getTrack(videoId: videoId) {
            return cached
        }

        let context = persistence.viewContext
        let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "videoId == %@", videoId)

        return (try? context.fetch(request))?.first?.toTrack
    }

    private func pendingSuggestionTrack(videoId: String) -> Track? {
        guard let suggestion = pendingSuggestion, suggestion.videoId == videoId else { return nil }

        return resolveTrack(videoId: videoId) ?? Track(
            videoId: suggestion.videoId,
            title: suggestion.title,
            artists: [suggestion.artist],
            album: "",
            durationSeconds: 0,
            thumbnails: [],
            isExplicit: false,
            videoType: "UNKNOWN"
        )
    }

    private var pendingSuggestion: WalkDJSuggestion? {
        guard let data = defaults.data(forKey: Keys.pendingSuggestion) else { return nil }
        return try? JSONDecoder().decode(WalkDJSuggestion.self, from: data)
    }

    private func selectSuggestion() -> WalkDJSuggestion? {
        var candidates: [String: WalkDJCandidate] = [:]
        let now = Date()

        func merge(track: Track, score: Double, flag: WalkDJCandidate.Flag) {
            guard !track.videoId.isEmpty else { return }

            if var existing = candidates[track.videoId] {
                existing.score += score
                existing.flags.insert(flag)
                candidates[track.videoId] = existing
            } else {
                candidates[track.videoId] = WalkDJCandidate(track: track, score: score, flags: [flag])
            }
        }

        let context = persistence.viewContext

        let downloadRequest: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        downloadRequest.relationshipKeyPathsForPrefetching = ["track"]
        if let downloads = try? context.fetch(downloadRequest) {
            for download in downloads {
                guard let track = download.track?.toTrack else { continue }
                merge(track: track, score: 55, flag: .downloaded)
            }
        }

        let historyRequest: NSFetchRequest<CDPlayHistory> = CDPlayHistory.fetchRequest()
        historyRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDPlayHistory.playedAt, ascending: false)]
        historyRequest.fetchLimit = 200
        historyRequest.relationshipKeyPathsForPrefetching = ["track"]
        if let history = try? context.fetch(historyRequest) {
            var counts: [String: Int] = [:]
            var latestPlay: [String: Date] = [:]
            var tracksById: [String: Track] = [:]

            for entry in history {
                guard let track = entry.track?.toTrack else { continue }
                counts[track.videoId, default: 0] += 1
                latestPlay[track.videoId] = max(latestPlay[track.videoId] ?? .distantPast, entry.playedAt)
                tracksById[track.videoId] = track
            }

            for (videoId, track) in tracksById {
                let playCount = counts[videoId, default: 0]
                let latest = latestPlay[videoId] ?? .distantPast
                var score = min(Double(playCount) * 6, 26)

                if hourDistance(from: latest, to: now) <= 2 {
                    score += 12
                    merge(track: track, score: 12, flag: .timeOfDay)
                }

                let sinceLastPlay = now.timeIntervalSince(latest)
                if sinceLastPlay < 2 * 60 * 60 {
                    score -= 30
                } else if sinceLastPlay < 12 * 60 * 60 {
                    score -= 8
                }

                merge(track: track, score: score, flag: .recent)
            }
        }

        for likedId in PlaylistManager.shared.likedTracks {
            if let track = resolveTrack(videoId: likedId) {
                merge(track: track, score: 24, flag: .liked)
            }
        }

        for memoryVideoId in SongMemoryManager.shared.memoriesByVideoId.keys {
            if let track = resolveTrack(videoId: memoryVideoId) {
                merge(track: track, score: 18, flag: .memory)
            }
        }

        let veryRecentIds = Set(dataManager.recentlyPlayed.prefix(3).map(\.videoId))

        let best = candidates.values
            .filter { !veryRecentIds.contains($0.track.videoId) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.track.title < rhs.track.title
                }
                return lhs.score > rhs.score
            }
            .first

        guard let best else { return nil }

        return WalkDJSuggestion(
            videoId: best.track.videoId,
            title: best.track.title,
            artist: best.track.displayArtist,
            reason: reason(for: best),
            createdAt: now
        )
    }

    private func reason(for candidate: WalkDJCandidate) -> String {
        if candidate.flags.contains(.memory) {
            return "One of your memory songs feels right for this walk."
        }
        if candidate.flags.contains(.downloaded) && candidate.flags.contains(.timeOfDay) {
            return "From your library, and it fits this time of day."
        }
        if candidate.flags.contains(.liked) {
            return "You liked this one, so Walk DJ pulled it forward."
        }
        if candidate.flags.contains(.timeOfDay) {
            return "You tend to reach for this around now."
        }
        if candidate.flags.contains(.downloaded) {
            return "From your library and ready to go."
        }
        return "You keep coming back to this one."
    }

    private func hourDistance(from first: Date, to second: Date) -> Int {
        let calendar = Calendar.current
        let firstHour = calendar.component(.hour, from: first)
        let secondHour = calendar.component(.hour, from: second)
        let diff = abs(firstHour - secondHour)
        return min(diff, 24 - diff)
    }

    private func refreshStatusText() {
        guard isEnabled else {
            statusText = "Adaptive Walk DJ is off."
            return
        }

        guard CMMotionActivityManager.isActivityAvailable() else {
            statusText = "Walking detection is unavailable on this device."
            return
        }

        let motionStatus = CMMotionActivityManager.authorizationStatus()
        switch motionStatus {
        case .denied, .restricted:
            statusText = "Enable Motion & Fitness to let Walk DJ detect walks."
            return
        default:
            break
        }

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                if settings.authorizationStatus == .denied {
                    self.statusText = "Enable notifications so Walk DJ can suggest songs."
                } else if self.isMonitoringMotion {
                    self.statusText = "Walk DJ is ready for your next walk."
                } else {
                    self.statusText = "Walk DJ is preparing its sensors."
                }
            }
        }
    }
}
