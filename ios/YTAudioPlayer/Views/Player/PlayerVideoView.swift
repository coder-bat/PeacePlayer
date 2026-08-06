//
//  PlayerVideoView.swift
//  YTAudioPlayer
//
//  S17-H / FORMAT-18-FAST (2026-08-07):
//  SwiftUI wrapper around AVPlayerLayer. Points at the same
//  AVPlayer that drives audio playback so the iOS 26
//  PlayerRemoteXPC video-receiver subsystem has a CALayer to
//  target. Without this, iOS 26 throws
//  `kFigPlayerError_ParamErr` on `clearVideoLayer`
//  ("Not supported when FigUseVideoReceiverForCALayer") and
//  playback fails. The layer is also what renders the
//  YouTube music video (format 18, 360x360 H.264) during
//  cold plays — the video just shows up in the UI as a
//  bonus.
//
//  ## Why a UIViewRepresentable (not SwiftUI's `VideoPlayer`)
//
//  `VideoPlayer` from AVKit:
//
//  1. Inserts its own AVPlayer (you can't reuse your existing
//     audio player, which means the visualizer tap, the
//     time observer, and the now-playing service all need
//     to be re-wired to a second player).
//  2. Includes its own chrome / playback controls (we
//     already have our own).
//  3. Is the wrong layer class — it draws controls on top
//     of the layer, not as a layer-backed view. The
//     PlayerRemoteXPC fix needs the layer to BE an
//     AVPlayerLayer, period.
//
//  Wrapping AVPlayerLayer in a UIView and putting that
//  into a UIViewRepresentable gives us:
//
//  - the exact layer class iOS 26 wants
//  - reuse of the existing audio AVPlayer
//  - no extra chrome
//  - one place to configure gravity, etc.
//
//  ## Threading
//
//  `makeUIView` and `updateUIView` both run on the main
//  thread (UIViewRepresentable contract). Safe to assign
//  the player here.
//

import SwiftUI
import AVFoundation

/// UIView whose backing layer IS an AVPlayerLayer. This is
/// the only view class that satisfies iOS 26's
/// "FigUseVideoReceiverForCALayer" check — the player
/// subsystem queries the view's layer class, not whether
/// there's a "video view" in the hierarchy.
final class PlayerVideoUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerVideoView: UIViewRepresentable {
    let player: AVPlayer?
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerVideoUIView {
        let view = PlayerVideoUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = videoGravity
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerVideoUIView, context: Context) {
        // Only re-assign when the player reference actually
        // changes — otherwise we'd reset the currentItem on
        // every body re-render and cause a visible
        // re-buffer. The !== check uses object identity
        // (the AVPlayer is replaced wholesale on every
        // play(item:) call), so this triggers exactly when
        // a new track starts.
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
}
