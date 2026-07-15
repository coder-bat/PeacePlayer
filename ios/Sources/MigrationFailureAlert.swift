//
//  MigrationFailureAlert.swift
//  YTAudioPlayer
//
//  S17-D (CV-6): presents a UIAlertController when the Core
//  Data persistent store fails to load. The user gets to
//  choose between backing up the broken store and starting
//  fresh, or just starting fresh.
//
//  We deliberately do this in UIKit (UIAlertController +
//  UIWindowScene) rather than a SwiftUI .alert() modifier
//  because the read-only constraint for S17-D forbids
//  editing any existing view file, and we need the alert
//  to appear over whatever SwiftUI view is on screen
//  without injecting ourselves into the view tree.
//
//  Activation:
//  - The singleton is referenced by
//    PersistenceController.init via `MigrationFailureAlert.shared`.
//    That reference forces Swift to load this file, which
//    runs the NotificationCenter observer registration. By
//    the time PersistenceController's load callback fires,
//    the listener is already in place.
//  - As a second line of defense, we observe
//    PersistenceController.shared.loadState via Combine so
//    we still catch a failure if the notification was
//    somehow missed (e.g. if the listener was registered
//    after the load callback's main-queue block ran).
//

import UIKit
import Combine
import os

final class MigrationFailureAlert {
    static let shared = MigrationFailureAlert()

    private static let log = Logger(subsystem: "com.ytaudioplayer.PeacePlayer", category: "MigrationFailureAlert")

    private var cancellables: Set<AnyCancellable> = []
    /// Tracks whether we've already presented the alert for
    /// the current failure. We don't want a second
    /// notification (e.g. from a duplicate load attempt) to
    /// re-present while the first alert is still on screen.
    private var hasPresentedForCurrentFailure: Bool = false

    private init() {
        // Primary path: the explicit notification posted by
        // PersistenceController. This is the one we expect
        // to fire in normal flow.
        NotificationCenter.default.publisher(for: .persistentStoreMigrationFailed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleFailure(error: note.userInfo?["error"] as? Error)
            }
            .store(in: &cancellables)

        // Backup path: observe the published loadState. If
        // the notification was missed (timing edge case during
        // launch), the state transition still fires here and
        // we re-attempt the alert.
        PersistenceController.shared.$loadState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .migrationFailed = state {
                    self?.handleFailure(error: PersistenceController.shared.lastError)
                }
            }
            .store(in: &cancellables)

        Self.log.info("MigrationFailureAlert installed; listening for persistent-store failures")
    }

    private func handleFailure(error: Error?) {
        guard !hasPresentedForCurrentFailure else { return }
        hasPresentedForCurrentFailure = true

        // The window scene may not be active yet on cold
        // launch — PersistenceController.shared is touched
        // in @main init, and the Core Data callback can fire
        // before the SwiftUI view tree has a window. Retry
        // briefly until we have a presentable view controller.
        attemptPresentation(error: error, attempt: 0)
    }

    private func attemptPresentation(error: Error?, attempt: Int) {
        if let topVC = topMostViewController() {
            present(alertOn: topVC, error: error)
            return
        }
        if attempt >= 20 {
            // ~5s of retrying. Past this, just log and let
            // the user re-trigger via... actually we have no
            // re-trigger. The next launch will hit the same
            // failure and try again.
            Self.log.error("No view controller available to present the migration-failure alert after \(attempt) attempts. User will see the broken app until relaunch.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attemptPresentation(error: error, attempt: attempt + 1)
        }
    }

    private func present(alertOn host: UIViewController, error: Error?) {
        let alert = UIAlertController(
            title: "Library couldn't be migrated",
            message: alertMessage(error: error),
            preferredStyle: .alert
        )

        // Default / recommended action: back up the broken
        // store to a sibling file (the user can pull it via
        // iTunes file sharing) and start fresh. This is
        // "keep old (read-only)" in the spirit of the S17-D
        // plan — the old data is preserved on disk, even
        // though the in-app state is empty.
        alert.addAction(UIAlertAction(title: "Back up & start fresh", style: .default) { [weak self] _ in
            self?.resetPresentationFlag()
            PersistenceController.shared.backupAndReload()
        })

        // Destructive option: wipe the broken store outright.
        // The previous code did this implicitly. Now it's
        // explicit so the user knows they're losing data.
        alert.addAction(UIAlertAction(title: "Start fresh", style: .destructive) { [weak self] _ in
            self?.resetPresentationFlag()
            PersistenceController.shared.wipeAndReload()
        })

        // Cancel option: do nothing. The user can try
        // restarting the app — if the underlying error was
        // transient (e.g. iCloud sync mid-write, file
        // system hiccup), a relaunch may succeed. If it
        // doesn't, the alert fires again on the next launch.
        alert.addAction(UIAlertAction(title: "Try again later", style: .cancel) { [weak self] _ in
            self?.resetPresentationFlag()
        })

        Self.log.notice("Presenting migration-failure alert")
        host.present(alert, animated: true)
    }

    private func resetPresentationFlag() {
        hasPresentedForCurrentFailure = false
    }

    private func alertMessage(error: Error?) -> String {
        let detail: String
        if let nsError = error as NSError? {
            // NSPersistentStoreSaveError / migration errors
            // land in the same domain. We don't surface the
            // raw code to the user (it means nothing to
            // them) but we do log it in the previous
            // PersistenceController commit, so the support
            // path has the data.
            detail = "Your saved music library, playlists, and Time Capsules couldn't be opened in the new version of PeacePlayer."
        } else {
            detail = "Your saved music library, playlists, and Time Capsules couldn't be opened in the new version of PeacePlayer."
        }
        return """
        \(detail)

        Choose "Back up & start fresh" to preserve the old data on your device before continuing. The backed-up file is accessible through Finder / iTunes file sharing.
        """
    }

    /// Walks the active window scene's view-controller stack
    /// to find the topmost presented view controller. The
    /// topmost is what we present on — presenting on a
    /// mid-stack controller would put the alert behind
    /// anything the user is already looking at.
    private func topMostViewController() -> UIViewController? {
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        for scene in activeScenes {
            for window in scene.windows where window.isKeyWindow {
                guard var top = window.rootViewController else { continue }
                while let presented = top.presentedViewController {
                    top = presented
                }
                return top
            }
        }
        return nil
    }
}
