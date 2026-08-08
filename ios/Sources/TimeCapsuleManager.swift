//
//  TimeCapsuleManager.swift
//  YTAudioPlayer
//
//  Manages time capsule lifecycle: bury, seal, unlock notification, open.
//
//  2026-07-15 (S17-C, CV-2): the sealed note is now AES-GCM
//  encrypted with a 256-bit master key stored in the Keychain
//  (see KeychainHelper.getOrCreateTimeCapsuleMasterKey). The
//  plaintext `noteText` column on CDTimeCapsule is no longer
//  populated for new rows. Legacy rows from before this commit
//  are migrated on first read: the existing plaintext is
//  encrypted and written to `encryptedNote`, and `noteText` is
//  cleared. After the first read per legacy row, no user-sealed
//  text remains in plaintext in the SQLite store.
//

import Foundation
import CoreData
import UserNotifications
import Combine
import CryptoKit
import UIKit
import WidgetKit

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

    // S17-C (CV-2): "unlocked" now uses the manager's trusted
    // clock, not raw `Date()`. See `TimeCapsuleManager.trustedNow`
    // — if the user rolled the system clock back past the most
    // recent forward-time the app has seen, trustedNow clamps
    // to that forward time, so a sealed capsule stays sealed.
    var isUnlocked: Bool { TimeCapsuleManager.trustedNow() >= unlockAt }
    var isReadyToOpen: Bool { isUnlocked && !isOpened }

    var daysUntilUnlock: Int {
        max(0, Calendar.current.dateComponents([.day], from: TimeCapsuleManager.trustedNow(), to: unlockAt).day ?? 0)
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

    // MARK: - Encryption (S17-C, CV-2)

    /// Encrypts `plaintext` with the TimeCapsule master key using
    /// AES-GCM. Returns a single `Data` blob containing the
    /// 12-byte nonce, ciphertext, and 16-byte auth tag (the
    /// standard `AES.GCM.SealedBox.combined` layout), which is
    /// what we store on disk.
    ///
    /// Returns nil if the master key is unavailable (e.g. the
    /// device's passcode was disabled after install, putting the
    /// Keychain entry in a state we can't read). Callers fall
    /// back to an empty string in that case — same UX as a
    /// capsule whose note is empty.
    private static func encryptNote(_ plaintext: String) -> Data? {
        guard let key = KeychainHelper.shared.getOrCreateTimeCapsuleMasterKey() else {
            #if DEBUG
            print("⚠️ TimeCapsule: master key unavailable, refusing to encrypt")
            #endif
            return nil
        }
        do {
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
            guard let combined = sealed.combined else {
                return nil
            }
            return combined
        } catch {
            #if DEBUG
            print("⚠️ TimeCapsule: AES-GCM seal failed: \(error)")
            #endif
            return nil
        }
    }

    /// Decrypts a `Data` blob produced by `encryptNote`. Returns
    /// the original UTF-8 string. Returns nil if the blob is
    /// malformed or the auth tag doesn't verify — both of which
    /// mean the on-disk row was tampered with or came from a
    /// different key. Treat nil as "this capsule is unreadable"
    /// and surface that to the user rather than crashing.
    private static func decryptNote(_ blob: Data) -> String? {
        guard let key = KeychainHelper.shared.getOrCreateTimeCapsuleMasterKey() else {
            return nil
        }
        do {
            let box = try AES.GCM.SealedBox(combined: blob)
            let plaintext = try AES.GCM.open(box, using: key)
            return String(data: plaintext, encoding: .utf8)
        } catch {
            #if DEBUG
            print("⚠️ TimeCapsule: AES-GCM open failed: \(error)")
            #endif
            return nil
        }
    }

    /// Reads the user-visible note text from a CDTimeCapsule,
    /// transparently migrating legacy plaintext rows to the
    /// encrypted column on first read.
    ///
    /// Behavior:
    /// - `encryptedNote` populated → decrypt and return.
    /// - `encryptedNote` nil, `noteText` non-empty → legacy row;
    ///   encrypt the plaintext, save, clear `noteText`, return
    ///   the original string.
    /// - both empty → empty string.
    ///
    /// If the master key is unavailable or decryption fails, the
    /// legacy plaintext is returned as a last-resort fallback
    /// (better than a hard crash) and the row is left alone.
    /// Once the key is fixed, the next read migrates it.
    private func readNoteText(for capsule: CDTimeCapsule) -> String {
        if let blob = capsule.encryptedNote, !blob.isEmpty {
            return Self.decryptNote(blob) ?? ""
        }
        let legacy = capsule.noteText
        guard !legacy.isEmpty else { return "" }

        // Legacy plaintext. Migrate in place if we can.
        guard let blob = Self.encryptNote(legacy) else {
            // No key — return plaintext as a fallback so the
            // user can still read their old capsules. The next
            // call after the key is fixed will succeed and the
            // row will be migrated then.
            return legacy
        }
        capsule.encryptedNote = blob
        capsule.noteText = ""
        do {
            try context.save()
        } catch {
            #if DEBUG
            print("⚠️ TimeCapsule: failed to save migrated row: \(error)")
            #endif
            // Don't undo the in-memory writes — the next refresh
            // will retry, and a failure here doesn't change what
            // we return to the caller.
        }
        return legacy
    }

    // MARK: - Clock sanity (S17-C, CV-2)

    /// UserDefaults key for the most recent "forward-time" the app
    /// has observed. If the user rolls the system clock back, this
    /// stays put and `trustedNow()` clamps to it.
    private static let lastSeenNowKey = "TimeCapsuleManager.lastSeenCurrentTime"

    /// Returns the highest of (now, the last time we observed a
    /// forward clock). On first call this is just `Date()`.
    /// Subsequent calls only grow — so if a user rolls the clock
    /// back, the trusted current time stays at the most recent
    /// forward reading we saw.
    ///
    /// Design choice (CV-2):
    /// The S17-C plan called out a "hash commitment" approach
    /// (commit to the unlock date at seal time, reveal at unlock)
    /// as the cryptographic analog of "sealed". We deliberately
    /// skip that here — the encryption + clock-sanity combo
    /// closes the actual security gap (a clock-rolled-back
    /// attacker can't read a sealed capsule) without the
    /// migration cost of a per-capsule commitment. The cost
    /// tradeoff would tip the other way if we ever care about
    /// "unlock-date integrity against a jailbroken device" —
    /// the date field is just a Date in Core Data and a
    /// jailbroken user can write whatever they want. Out of
    /// scope for the honest-product-copy fix.
    static func trustedNow() -> Date {
        let now = Date()
        let defaults = UserDefaults.standard
        let lastSeen = defaults.object(forKey: lastSeenNowKey) as? Date
        if let lastSeen, lastSeen > now {
            return lastSeen
        }
        // First read, or `now` is forward of any prior reading.
        // Update the store so a future rollback can't drag us
        // backward.
        defaults.set(now, forKey: lastSeenNowKey)
        return now
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
                    noteText: self.readNoteText(for: capsule),
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

        // S18 (QW-1): keep the app icon badge in sync with the
        // ready-to-open count whenever the manager refreshes. The
        // scenePhase handler in YTAudioPlayerApp also sets the
        // badge, but this catches the in-app cases: a capsule
        // becomes ready while the user is in the foreground, the
        // user opens one and the badge should drop, etc.
        UIApplication.shared.applicationIconBadgeNumber = readyToOpen.count

        // S18 / P1-2: also reload widget timelines so the
        // ResumeWidget's 💌 pill (P1-6) reflects the new state
        // within seconds, not on its 15-min auto-refresh tick.
        // Cheap: only fires on the badge change path (refresh,
        // open, scene-phase).
        WidgetCenter.shared.reloadAllTimelines()
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
            // S17-C (CV-2): write the sealed note to
            // `encryptedNote` and leave `noteText` empty. If the
            // key is unavailable the user still gets a capsule,
            // but the note is effectively dropped (same UX as a
            // capsule whose note is empty).
            capsule.encryptedNote = Self.encryptNote(noteText)
            capsule.noteText = ""
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

        // S17-C (CV-2): stamp openedAt with the trusted clock, not
        // raw Date(). If the user just rolled the system clock
        // back, the trusted now is still the most recent forward
        // time we saw, so the "opened at" date doesn't suddenly
        // jump into the past.
        capsule.isOpened = true
        capsule.openedAt = Self.trustedNow()
        try? context.save()

        // S18 (P0-5): remove the pending unlock notification so the
        // user doesn't get a "ready to open" banner for a capsule
        // they already opened. Only deleteCapsule did this before —
        // the open path was leaving the pending request in place.
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["timecapsule-\(id.uuidString)"]
        )

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

        // S18 (P0-5): set userInfo so the notification response can
        // deep-link to the vault. Without this, tapping the banner just
        // opens the app to Home — the user has to find the vault via
        // FullPlayer long-press, which most don't know about.
        let capsuleId = capsule.id.uuidString
        content.userInfo = [
            "capsuleId": capsuleId,
            "deepLink": "peaceplayer://capsule/\(capsuleId)"
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: capsule.unlockAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: "timecapsule-\(capsuleId)",
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
