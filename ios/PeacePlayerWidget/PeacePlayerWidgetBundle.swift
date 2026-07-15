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
        // S17-E: iOS 18 Control Center / Lock Screen / Action Button
        // widgets. Reuses the existing transport AppIntents, so there's
        // no new command surface — just a new presentation surface.
        // Three separate ControlWidgets (one per transport action) so
        // the user can pin any subset. See ControlWidget.swift for why
        // we don't bundle them into one widget.
        if #available(iOS 18.0, *) {
            PeacePlayerControlWidget()
            PeacePlayerControlWidgetSkipNext()
            PeacePlayerControlWidgetSkipPrevious()
        }
    }
}
