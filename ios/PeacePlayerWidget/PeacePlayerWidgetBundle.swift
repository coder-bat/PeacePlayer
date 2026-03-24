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
        }
        ResumeWidget()
        ShuffleFavoritesWidget()
        PlaylistsWidget()
    }
}
