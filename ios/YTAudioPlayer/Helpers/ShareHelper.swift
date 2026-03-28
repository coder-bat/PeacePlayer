//
//  ShareHelper.swift
//  YTAudioPlayer
//
//  Utility for sharing tracks from anywhere in the app
//

import UIKit
import SwiftUI

struct ShareHelper {
    static func shareTrack(title: String, artist: String, videoId: String) {
        let text = "\(title) - \(artist)"
        let youtubeURL = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
        
        let activityVC = UIActivityViewController(
            activityItems: [text, youtubeURL],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = rootVC.view
                popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            rootVC.present(activityVC, animated: true)
        }
    }
    
    static func copyTrackInfo(title: String, artist: String) {
        UIPasteboard.general.string = "\(title) - \(artist)"
        HapticManager.success()
    }
}
