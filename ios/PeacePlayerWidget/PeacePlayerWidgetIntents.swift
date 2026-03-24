//
//  PeacePlayerWidgetIntents.swift
//  PeacePlayerWidget
//
//  AppIntents for interactive widget buttons (iOS 17+).
//  Posts Darwin notifications for real-time control when the app is backgrounded.
//  Also writes UserDefaults fallback for when the app is fully suspended.
//

import AppIntents
import Foundation

@available(iOSApplicationExtension 17.0, *)
struct WidgetPlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Toggles playback in PeacePlayer.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        SharedNowPlayingState.postDarwinNotification(DarwinCmd.playPause)
        SharedNowPlayingState.writePendingCommand(.playPause)  // fallback: app was fully suspended
        return .result()
    }
}

@available(iOSApplicationExtension 17.0, *)
struct WidgetSkipNextIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Next"
    static var description = IntentDescription("Skips to the next track.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        SharedNowPlayingState.postDarwinNotification(DarwinCmd.skipNext)
        SharedNowPlayingState.writePendingCommand(.skipNext)
        return .result()
    }
}

@available(iOSApplicationExtension 17.0, *)
struct WidgetSkipPreviousIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Previous"
    static var description = IntentDescription("Returns to the previous track.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        SharedNowPlayingState.postDarwinNotification(DarwinCmd.skipPrevious)
        SharedNowPlayingState.writePendingCommand(.skipPrevious)
        return .result()
    }
}

@available(iOSApplicationExtension 17.0, *)
struct WidgetSeekForwardIntent: AppIntent {
    static var title: LocalizedStringResource = "Seek Forward 15s"
    static var description = IntentDescription("Seeks forward 15 seconds.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        SharedNowPlayingState.postDarwinNotification(DarwinCmd.seekForward)
        return .result()
    }
}

@available(iOSApplicationExtension 17.0, *)
struct WidgetSeekBackwardIntent: AppIntent {
    static var title: LocalizedStringResource = "Seek Backward 15s"
    static var description = IntentDescription("Seeks backward 15 seconds.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        SharedNowPlayingState.postDarwinNotification(DarwinCmd.seekBackward)
        return .result()
    }
}

@available(iOSApplicationExtension 17.0, *)
struct WidgetVolumeUpIntent: AppIntent {
    static var title: LocalizedStringResource = "Volume Up"
    static var description = IntentDescription("Increases playback volume.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        SharedNowPlayingState.postDarwinNotification(DarwinCmd.volumeUp)
        return .result()
    }
}

@available(iOSApplicationExtension 17.0, *)
struct WidgetVolumeDownIntent: AppIntent {
    static var title: LocalizedStringResource = "Volume Down"
    static var description = IntentDescription("Decreases playback volume.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        SharedNowPlayingState.postDarwinNotification(DarwinCmd.volumeDown)
        return .result()
    }
}

@available(iOSApplicationExtension 17.0, *)
struct WidgetSetVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Volume"
    static var description = IntentDescription("Sets playback volume to a specific level.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Level") var level: Double

    func perform() async throws -> some IntentResult {
        SharedNowPlayingState.writePendingVolume(level)
        SharedNowPlayingState.postDarwinNotification(DarwinCmd.setVolume)
        return .result()
    }
}
