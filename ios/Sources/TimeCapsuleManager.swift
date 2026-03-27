//
//  TimeCapsuleManager.swift
//  YTAudioPlayer
//
//  Manages time capsule lifecycle: bury, seal, unlock notification, open.
//

import Foundation
import CoreData
import UserNotifications
import Combine

struct TimeCapsuleSnapshot: Identifiable, Equatable {
    let id: UUID
    let videoId: String
    let trackTitle: String
    let trackArtist: String
    let artworkURL: URL?
    let noteText: String
    let mood: String?
    let createdAt: Date
    let unlockAt: Date
    let isOpened: Bool
    let openedAt: Date?

    var isUnlocked: Bool { Date() >= unlockAt }
    var isReadyToOpen: Bool { isUnlocked && !isOpened }

    var daysUntilUnlock: Int {
        max(0, Calendar.current.dateComponents([.day], from: Date(), to: unlockAt).day ?? 0)
    }
}

final class TimeCapsuleManager: ObservableObject {
    static let shared = TimeCapsuleManager()

    @Published var capsules: [TimeCapsuleSnapshot] = []

    private let context: NSManagedObjectContext

    private init() {
        self.context = PersistenceController.shared.viewContext
        refresh()
    }

    // MARK: - Read

    func refresh() {
        let request = CDTimeCapsule.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "unlockAt", ascending: true)]

        do {
            let results = try context.fetch(request)
            capsules = results.compactMap { capsule in
                guard let track = capsule.track else { return nil }
                return TimeCapsuleSnapshot(
                    id: capsule.id,
                    videoId: track.videoId,
                    trackTitle: track.title,
                    trackArtist: track.displayArtist,
                    artworkURL: track.artworkURL,
                    noteText: capsule.noteText,
                    mood: capsule.mood,
                    createdAt: capsule.createdAt,
                    unlockAt: capsule.unlockAt,
                    isOpened: capsule.isOpened,
                    openedAt: capsule.openedAt
                )
            }
        } catch {
            capsules = []
        }
    }

    var pendingCapsules: [TimeCapsuleSnapshot] {
        capsules.filter { !$0.isOpened && !$0.isUnlocked }
    }

    var readyToOpen: [TimeCapsuleSnapshot] {
        capsules.filter { $0.isReadyToOpen }
    }

    var openedCapsules: [TimeCapsuleSnapshot] {
        capsules.filter { $0.isOpened }
    }

    // MARK: - Bury

    func buryCapsule(track: Track, noteText: String, unlockDate: Date, mood: String?) {
        context.perform { [weak self] in
            guard let self = self else { return }

            // Find or create CDTrack
            let trackRequest = CDTrack.fetchRequest()
            trackRequest.predicate = NSPredicate(format: "videoId == %@", track.videoId)
            let cdTrack = (try? self.context.fetch(trackRequest))?.first
                ?? CDTrack.from(track: track, context: self.context)

            let capsule = CDTimeCapsule(context: self.context)
            capsule.id = UUID()
            capsule.noteText = noteText
            capsule.createdAt = Date()
            capsule.unlockAt = unlockDate
            capsule.isOpened = false
            capsule.mood = mood
            capsule.track = cdTrack

            try? self.context.save()

            self.scheduleNotification(for: capsule, trackTitle: track.title)

            DispatchQueue.main.async {
                self.refresh()
            }
        }
    }

    // MARK: - Open

    func openCapsule(id: UUID) -> TimeCapsuleSnapshot? {
        let request = CDTimeCapsule.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        guard let capsule = (try? context.fetch(request))?.first,
              capsule.isUnlocked else { return nil }

        capsule.isOpened = true
        capsule.openedAt = Date()
        try? context.save()

        refresh()
        return capsules.first { $0.id == id }
    }

    // MARK: - Delete

    func deleteCapsule(id: UUID) {
        let request = CDTimeCapsule.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        if let capsule = (try? context.fetch(request))?.first {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["timecapsule-\(id.uuidString)"]
            )
            context.delete(capsule)
            try? context.save()
            refresh()
        }
    }

    // MARK: - Notifications

    private func scheduleNotification(for capsule: CDTimeCapsule, trackTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Time Capsule Ready 💌"
        content.body = "A capsule you buried with \"\(trackTitle)\" is ready to open"
        content.sound = .default
        content.categoryIdentifier = "TIME_CAPSULE"

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: capsule.unlockAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: "timecapsule-\(capsule.id.uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Check on app launch for any capsules that became unlocked while app was closed
    func checkForNewlyUnlocked() -> [TimeCapsuleSnapshot] {
        refresh()
        return readyToOpen
    }
}
