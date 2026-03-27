//
//  WalkDJAppDelegate.swift
//  YTAudioPlayer
//
//  Local notification delegate for Adaptive Walk DJ
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
        return true
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
