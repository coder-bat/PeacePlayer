//
//  DailyRecapNotifier.swift
//  PeacePlayer
//
//  S18 / v1.6 / P1-7
//
//  Schedules a daily "your last track" local notification when the
//  user hasn't played anything in 24+ hours. The notification fires
//  at 8pm local time and deep-links to peaceplayer://track/{videoId}
//  so tapping it resumes the last track.
//
//  Three things gate the recap:
//   1. The Labs flag `ff_daily_recap` (default OFF). The user
//      opts in via Settings → Labs.
//   2. The user must have actually played something recently —
//      if the recentlyPlayed list is empty, there's no last
//      track to surface, and we don't nag.
//   3. After 3 consecutive play days, the recap is permanently
//      disabled. This is the "user is engaged, no nag needed"
//      affordance — once they're listening regularly the
//      notification becomes noise. The flag survives across
//      launches; the only way to re-enable is via the toggle
//      (which clears the disabled flag).
//
//  Hooks:
//   - recordTrackPlay(): called from DataManager.addToRecentlyPlayed
//     every time a track enters the recents list. Updates the
//     consecutive-days counter and cancels any pending recap.
//   - evaluateRecapState(): called from the scenePhase observer
//     when the app returns to .active. Schedules the next 8pm
//     recap if 24h have elapsed since the last play.
//
//  Thread safety: matches DeepLinkIndex — no @MainActor. Calls
//  happen from the main thread (scene phase changes) and from
//  DataManager (which is @MainActor isolated but the call site
//  is fire-and-forget).
//

import Foundation
import UserNotifications

final class DailyRecapNotifier {
    static let shared = DailyRecapNotifier()

    private let pendingRecapId = "daily-recap"
    private let consecutiveEngagedDaysKey = "recapConsecutiveEngagedDays"
    private let lastEngagedDateKey = "recapLastEngagedDate"
    private let recapDisabledKey = "recapDisabled"

    private init() {}

    // MARK: - Track-play hook

    /// Call when a new track enters the recentlyPlayed list. Updates
    /// the consecutive-day counter and cancels any pending recap.
    /// If the user has played on 3 consecutive days, the recap is
    /// permanently disabled (UserDefaults flag).
    func recordTrackPlay() {
        // Always cancel any pending recap — the user is engaged
        // right now, so a "remind me to listen" notification
        // would be backwards.
        cancelPendingRecap()

        // If the user already hit 3 consecutive days in a prior
        // run, do nothing further. The recap is permanently off.
        if UserDefaults.standard.bool(forKey: recapDisabledKey) { return }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let last = UserDefaults.standard.object(forKey: lastEngagedDateKey) as? Date
        let lastDay = last.map { cal.startOfDay(for: $0) }

        var days = UserDefaults.standard.integer(forKey: consecutiveEngagedDaysKey)
        if let lastDay = lastDay {
            if lastDay == today {
                // Same calendar day — no change to the counter.
            } else if let yesterday = cal.date(byAdding: .day, value: -1, to: today),
                      lastDay == yesterday {
                // Consecutive day — bump the counter.
                days += 1
            } else {
                // Gap day — reset to 1 (today is day 1).
                days = 1
            }
        } else {
            // First play we've ever recorded.
            days = 1
        }
        UserDefaults.standard.set(days, forKey: consecutiveEngagedDaysKey)
        UserDefaults.standard.set(today, forKey: lastEngagedDateKey)

        if days >= 3 {
            // User is engaged. Stop nagging.
            UserDefaults.standard.set(true, forKey: recapDisabledKey)
        }
    }

    // MARK: - Foreground hook

    /// Call when the scene becomes active. Schedules the next 8pm
    /// recap if the user has been away from the app for 24+ hours
    /// and the recap hasn't been permanently disabled.
    func evaluateRecapState() {
        // Gate 1: feature flag.
        guard UserDefaults.standard.object(forKey: "ff_daily_recap") as? Bool ?? false else {
            cancelPendingRecap()
            return
        }
        // Gate 2: not permanently disabled.
        guard !UserDefaults.standard.bool(forKey: recapDisabledKey) else { return }

        // Gate 3: must have a "last track" to surface.
        guard let last = DataManager.shared.recentlyPlayed.first else {
            cancelPendingRecap()
            return
        }

        let now = Date()
        let hoursSince = now.timeIntervalSince(last.playedAt) / 3600
        if hoursSince < 24 {
            // User is fresh — no nag.
            cancelPendingRecap()
            return
        }

        scheduleRecap(for: last)
    }

    // MARK: - Scheduling

    private func scheduleRecap(for last: RecentTrack) {
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: Date())
        components.hour = 20
        components.minute = 0
        guard var fireDate = cal.date(from: components) else { return }

        // If 8pm today has already passed, schedule for tomorrow.
        if fireDate < Date() {
            fireDate = cal.date(byAdding: .day, value: 1, to: fireDate) ?? fireDate
        }

        let content = UNMutableNotificationContent()
        content.title = "Your last track 💿"
        content.body = "You were listening to \"\(last.title)\" — pick up where you left off?"
        content.sound = .default
        content.userInfo = [
            "videoId": last.videoId,
            "deepLink": "peaceplayer://track/\(last.videoId)"
        ]

        let triggerComponents = cal.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: triggerComponents,
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: pendingRecapId,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    func cancelPendingRecap() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [pendingRecapId]
        )
    }

    // MARK: - Reset (for testing / flag toggle)

    /// Called when the user flips the `ff_daily_recap` toggle. If
    /// they turn the flag OFF, cancel any pending recap. If they
    /// turn it ON, also clear the permanent-disable flag so they
    /// can re-enable after hitting 3 consecutive days.
    func handleFlagChange(enabled: Bool) {
        if enabled {
            UserDefaults.standard.removeObject(forKey: recapDisabledKey)
            UserDefaults.standard.removeObject(forKey: consecutiveEngagedDaysKey)
            UserDefaults.standard.removeObject(forKey: lastEngagedDateKey)
        } else {
            cancelPendingRecap()
        }
    }
}
