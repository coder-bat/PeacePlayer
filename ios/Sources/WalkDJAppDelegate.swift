//
//  WalkDJAppDelegate.swift
//  YTAudioPlayer
//
//  Local notification delegate for Adaptive Walk DJ
//  C-1 fix: also handles URLSession background completion events
//

import Foundation
import UIKit
import UserNotifications

final class WalkDJAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        AdaptiveWalkDJManager.shared.configure()

        // S18 / P1-7: register the TIME_CAPSULE notification
        // category with two actions. Even with the body of the
        // notification work flag-gated off, the category is
        // safe to register — actions only show when a user
        // long-presses the banner. The actions give us a hook
        // for future v1.6 work (Snooze, Mark as read).
        let openAction = UNNotificationAction(
            identifier: "TIME_CAPSULE_OPEN",
            title: "Open Capsule",
            options: [.foreground]
        )
        let snoozeAction = UNNotificationAction(
            identifier: "TIME_CAPSULE_SNOOZE",
            title: "Snooze 1 day",
            options: []
        )
        let capsuleCategory = UNNotificationCategory(
            identifier: "TIME_CAPSULE",
            actions: [openAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([capsuleCategory])

        // C-1 fix: scan for orphan downloads that completed while the app was
        // terminated. Without this, files saved to <Documents>/Downloads/ by
        // the URLSession background completion path are not registered in
        // Core Data and never appear in the Library.
        BackgroundDownloadService.shared.bootstrap()

        // S15: start Spotlight donation so the currently-playing
        // track is searchable from the iOS home screen / Lock
        // Screen / Siri Suggestions.
        Task { @MainActor in
            SpotlightService.shared.start()
        }

        // S15: start the Live Activity manager. Subscribes to
        // PlayerState; auto-starts / -updates / -ends the
        // Now Playing activity as the user changes tracks,
        // plays, and pauses. iOS 16.2+ only.
        if #available(iOS 16.2, *) {
            _ = LiveActivityManager.shared
        }

        return true
    }

    // C-1 fix: forward iOS's background URLSession completion handler to
    // BackgroundDownloadService. iOS calls this when the app is relaunched
    // (or woken) to deliver pending background download events. If we don't
    // store and invoke the handler, iOS keeps the app suspended indefinitely
    // and never finishes the background URLSession task lifecycle.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundDownloadService.shared.storeBackgroundCompletionHandler(completionHandler)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // S18 (P0-5): Time Capsule unlock notifications now carry
        // userInfo["capsuleId"] + userInfo["deepLink"]. Route to the
        // vault at the app root so the user lands on the actual
        // capsule instead of Home. The AdaptiveWalkDJ handler is
        // called too (no-op for non-Walk-DJ notifications).
        if let capsuleId = userInfo["capsuleId"] as? String {
            NotificationCenter.default.post(
                name: .openTimeCapsuleVault,
                object: nil,
                userInfo: ["capsuleId": capsuleId]
            )
        }

        AdaptiveWalkDJManager.shared.handleNotificationResponse(userInfo: userInfo)
        completionHandler()
    }
}
