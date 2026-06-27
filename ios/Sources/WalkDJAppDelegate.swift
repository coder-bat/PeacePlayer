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

        // C-1 fix: scan for orphan downloads that completed while the app was
        // terminated. Without this, files saved to <Documents>/Downloads/ by
        // the URLSession background completion path are not registered in
        // Core Data and never appear in the Library.
        BackgroundDownloadService.shared.bootstrap()

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
        AdaptiveWalkDJManager.shared.handleNotificationResponse(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }
}
