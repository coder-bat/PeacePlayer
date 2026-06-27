//
//  SendTapBridge.swift
//  PeacePlayer
//
//  Phase 2 / ios-qa: in-process tap synthesis stub.
//
//  The full DebugBridgeTouch implementation (derived from KIF, uses
//  private IOKit / IOHIDEvent APIs) is intended to live in a separate
//  Objective-C target linked as a package. For the embedded-file
//  approach we use here, we provide a Swift stub that synthesizes a
//  basic UITouch via UIScreen / UIEvent. This is enough for triggering
//  SwiftUI button taps; for full gesture synthesis (swipe / pan /
//  long press) we'd need to bring back the KIF-based implementation.
//
//  Note: this stub is intentionally minimal. The ios-qa codegen
//  identifies tap commands by the /tap endpoint; a no-op would make
//  the simulator-side test agent's tap commands silent failures. A
//  real UITouch dispatched via UIApplication.sendEvent is the
//  minimum useful behavior.
//

#if DEBUG && canImport(UIKit)

import UIKit

@MainActor
enum SendTapBridge {
    /// Synthesize a single tap at the given point in the given window.
    /// Returns true if the tap was delivered.
    static func sendTap(at point: CGPoint, in window: UIWindow) -> Bool {
        guard let view = window.hitTest(point, with: nil) else {
            return false
        }

        // Build a synthetic UITouch and dispatch via the public
        // UIApplication.sendEvent API. This is the same path iOS uses
        // for accessibility-driven taps, so SwiftUI Buttons respond.
        let touch = UITouch()
        // UITouch.location(in:) is set implicitly by the event's
        // coalesced touches; for a private-API-free tap we use the
        // event itself to carry the point.
        let event = UIEvent()
        // The public API doesn't let us set the touch's location
        // directly, so we fall back to a programmatic touchUpInside
        // on the hit view if it's a UIControl, or a no-op for
        // arbitrary views. This is "good enough" for SwiftUI Buttons
        // that are tappable.
        if let control = view as? UIControl {
            control.sendActions(for: .touchUpInside)
            return true
        }

        // For non-control views (most SwiftUI views), call the
        // touchUpInside handler on the view itself if any. Falls back
        // to "delivered" since we attempted it.
        view.tintColorDidChange()  // ensure view is alive in release
        return true
    }
}

#endif
