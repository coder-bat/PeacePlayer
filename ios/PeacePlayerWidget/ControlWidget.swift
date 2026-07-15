//
//  ControlWidget.swift
//  PeacePlayerWidget
//
//  S17-E: iOS 18 Control Center / Lock Screen / Action Button widget.
//  Surfaces the 3 most useful transport controls (skip-prev / play-pause
//  / skip-next) without opening the app. iOS 18+ — gated at every entry
//  point so the deployment target can stay at 17.0 for the rest of the
//  app and the rest of the widget extension.
//
//  Wiring notes:
//  - Reuses the existing `WidgetSkipPreviousIntent`, `WidgetPlayPauseIntent`,
//    and `WidgetSkipNextIntent` AppIntents. They post Darwin notifications
//    + write a UserDefaults fallback so the app picks the command up even
//    if it was fully suspended when the user tapped the Control Center
//    button. No new intent types are introduced here.
//  - ControlWidgetButton is the iOS 18 element. `Label` here shows the
//    SF Symbol + name in the Control Center picker and on the Lock Screen.
//  - `StaticControlConfiguration(kind:)` is the iOS 18 name for what
//    iOS 17 called a `StaticConfiguration` for widgets — same shape,
//    no TimelineProvider, no IntentConfiguration. The `kind` string
//    must be unique across the bundle.
//

import WidgetKit
import SwiftUI
import AppIntents

@available(iOS 18.0, *)
struct PeacePlayerControlWidget: ControlWidget {
    // S17-E: the iOS 18 `ControlWidgetTemplateBuilder` only accepts
    // a single child per `StaticControlConfiguration` (the SDK's
    // `buildBlock` takes one `Content`). The first attempt at 3
    // buttons in one widget compiled but was misleading — Apple
    // documents multi-button ControlWidgets but the builder as of
    // Xcode 26.5 (SDK iphonesimulator26.5) only emits a single
    // `buildBlock(_:)`. Cleanest fix: expose 3 separate ControlWidgets
    // (one per transport action) so the user can pin any subset
    // to Control Center / Lock Screen / Action Button. They all
    // reuse the same transport AppIntents, so no new command
    // surface is introduced.
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PeacePlayerControlWidget.PlayPause") {
            ControlWidgetButton(action: WidgetPlayPauseIntent()) {
                Label("Play / Pause", systemImage: "playpause.fill")
            }
        }
        .displayName("PeacePlayer Play/Pause")
        .description("Toggle PeacePlayer playback from Control Center, Lock Screen, or the Action Button.")
    }
}

@available(iOS 18.0, *)
struct PeacePlayerControlWidgetSkipNext: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PeacePlayerControlWidget.SkipNext") {
            ControlWidgetButton(action: WidgetSkipNextIntent()) {
                Label("Next Track", systemImage: "forward.fill")
            }
        }
        .displayName("PeacePlayer Next")
        .description("Skip to the next track in PeacePlayer from Control Center or the Lock Screen.")
    }
}

@available(iOS 18.0, *)
struct PeacePlayerControlWidgetSkipPrevious: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PeacePlayerControlWidget.SkipPrevious") {
            ControlWidgetButton(action: WidgetSkipPreviousIntent()) {
                Label("Previous Track", systemImage: "backward.fill")
            }
        }
        .displayName("PeacePlayer Previous")
        .description("Go back to the previous track in PeacePlayer from Control Center or the Lock Screen.")
    }
}
