//
//  PeacePlayerWidgetBundle.swift
//  PeacePlayerWidget
//
//  Widget extension entry point.
//

import WidgetKit
import SwiftUI

@main
struct PeacePlayerWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        if #available(iOSApplicationExtension 17.0, *) {
            NowPlayingFullWidget()
            // S12: vinyl-record-styled medium widget
            VinylNowPlayingWidget()
        }
        ResumeWidget()
        ShuffleFavoritesWidget()
        PlaylistsWidget()
        // S15: Lock Screen / Dynamic Island / StandBy Live
        // Activity for the currently-playing track. iOS 16.1+.
        // The struct itself is `@available(iOS 16.1, *)` so on
        // older iOS versions the widget bundle is unchanged
        // (the activity just never appears on those devices).
        if #available(iOS 16.1, *) {
            NowPlayingLiveActivityWidget()
        }
    }
}
