//
//  GestureEngine.swift
//  YTAudioPlayer
//
//  Central gesture recognition and handling
//

import SwiftUI
import UIKit

/// Central engine for handling all custom gestures
class GestureEngine {
    static let shared = GestureEngine()
    
    // MARK: - Haptic Feedback
    
    let impactLight = UIImpactFeedbackGenerator(style: .light)
    let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    let notificationFeedback = UINotificationFeedbackGenerator()
    let selectionFeedback = UISelectionFeedbackGenerator()
    
    // MARK: - Velocity Tracking
    
    private var velocityTracker: VelocityTracker?
    
    // MARK: - Public Methods
    
    func prepareHaptics() {
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        selectionFeedback.prepare()
    }
    
    func triggerHaptic(_ type: HapticType) {
        switch type {
        case .skip:
            impactMedium.impactOccurred()
        case .queue:
            impactLight.impactOccurred()
        case .dismiss:
            impactHeavy.impactOccurred()
        case .error:
            notificationFeedback.notificationOccurred(.error)
        case .success:
            notificationFeedback.notificationOccurred(.success)
        case .selection:
            selectionFeedback.selectionChanged()
        case .scrubTick:
            impactLight.impactOccurred(intensity: 0.3)
        }
    }
    
    // MARK: - Gesture Recognition Helpers
    
    func detectFlickVelocity(_ velocity: CGPoint) -> FlickDirection? {
        let threshold: CGFloat = 500 // points per second
        
        if velocity.x > threshold {
            return .right
        } else if velocity.x < -threshold {
            return .left
        } else if velocity.y > threshold {
            return .down
        } else if velocity.y < -threshold {
            return .up
        }
        
        return nil
    }
    
    func calculateProgress(from start: CGFloat, current: CGFloat, total: CGFloat) -> Double {
        let delta = current - start
        return Double(min(max(delta / total, 0), 1))
    }
}

// MARK: - Types

enum HapticType {
    case skip
    case queue
    case dismiss
    case error
    case success
    case selection
    case scrubTick
}

enum FlickDirection {
    case left
    case right
    case up
    case down
}

// MARK: - Velocity Tracker

class VelocityTracker {
    private var samples: [(position: CGPoint, time: TimeInterval)] = []
    private let maxSamples = 5
    
    func addSample(position: CGPoint) {
        let now = CACurrentMediaTime()
        samples.append((position, now))
        
        // Keep only recent samples
        if samples.count > maxSamples {
            samples.removeFirst()
        }
    }
    
    func calculateVelocity() -> CGPoint {
        guard samples.count >= 2 else { return .zero }
        
        let first = samples.first!
        let last = samples.last!
        
        let deltaTime = last.time - first.time
        guard deltaTime > 0 else { return .zero }
        
        let deltaX = last.position.x - first.position.x
        let deltaY = last.position.y - first.position.y
        
        return CGPoint(
            x: deltaX / CGFloat(deltaTime),
            y: deltaY / CGFloat(deltaTime)
        )
    }
    
    func reset() {
        samples.removeAll()
    }
}
