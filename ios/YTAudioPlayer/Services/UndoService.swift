//
//  UndoService.swift
//  YTAudioPlayer
//
//  Manages undo actions with auto-dismiss timer
//

import Foundation
import Combine

struct UndoAction {
    let id: UUID
    let message: String
    let restore: () -> Void
    let createdAt: Date
}

class UndoService: ObservableObject {
    static let shared = UndoService()
    
    @Published var currentUndo: UndoAction?
    
    private var dismissTimer: Timer?
    private let undoWindow: TimeInterval = 5.0
    
    private init() {}
    
    func registerUndo(message: String, restore: @escaping () -> Void) {
        dismissCurrentUndo()
        
        let action = UndoAction(
            id: UUID(),
            message: message,
            restore: restore,
            createdAt: Date()
        )
        
        DispatchQueue.main.async {
            self.currentUndo = action
        }
        
        dismissTimer = Timer.scheduledTimer(withTimeInterval: undoWindow, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.currentUndo = nil
            }
        }
    }
    
    func executeUndo() {
        guard let action = currentUndo else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        action.restore()
        DispatchQueue.main.async {
            self.currentUndo = nil
        }
    }
    
    func dismissCurrentUndo() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        DispatchQueue.main.async {
            self.currentUndo = nil
        }
    }
}
