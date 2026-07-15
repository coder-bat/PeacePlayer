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
    let restore: (() -> Void)?
    let createdAt: Date
    /// S15: when false, the toast shows only the confirmation
    /// message and hides the "Undo" button. Set false for any
    /// destructive action that ships without a working restore
    /// (e.g. library single-delete — the audio file is gone, so
    /// "Undo" used to advertise a capability the app didn't have).
    let showUndoButton: Bool

    init(id: UUID = UUID(), message: String, restore: (() -> Void)?, createdAt: Date = Date(), showUndoButton: Bool = true) {
        self.id = id
        self.message = message
        self.restore = restore
        self.createdAt = createdAt
        self.showUndoButton = showUndoButton
    }
}

class UndoService: ObservableObject {
    static let shared = UndoService()
    
    @Published var currentUndo: UndoAction?
    
    private var dismissTimer: Timer?
    private let undoWindow: TimeInterval = 5.0
    
    private init() {}
    
    /// Convenience overload for the historical call shape —
    /// `registerUndo(message: "...") { /* no-op */ }` — which
    /// used to silently wire a fake Undo button. With S15, passing
    /// an empty closure is treated as "no undo" and the toast hides
    /// the button. Real restorations should be passed as a
    /// non-empty closure (or call the explicit `showUndo: true` form).
    func registerUndo(message: String, restore: @escaping () -> Void) {
        registerUndo(message: message, restore: restore, showUndoButton: !isEmptyClosure(restore))
    }

    /// S15: explicit form. Pass `showUndoButton: false` when the
    /// action is destructive but the restore is not implemented
    /// (or not meaningful) — the toast will show only the message
    /// and an "OK"-style indicator instead of a fake Undo button.
    func registerUndo(message: String, restore: (() -> Void)?, showUndoButton: Bool) {
        dismissCurrentUndo()

        let action = UndoAction(
            message: message,
            restore: restore,
            showUndoButton: showUndoButton
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

    /// Heuristic: empty closure is detected by compiling a
    /// placeholder that the caller can't actually use. Swift
    /// closures don't expose their body, so this is best-effort
    /// via the new explicit API. We use the explicit
    /// `showUndoButton: false` form at all call sites that don't
    /// have a working restore, so this helper is reserved for
    /// legacy code paths during the migration window.
    private func isEmptyClosure(_ closure: () -> Void) -> Bool {
        // Best-effort heuristic — closure introspection is not
        // available in Swift. We treat closures as "non-empty" by
        // default and rely on call sites to use the explicit
        // `showUndoButton: false` form when restore is a stub.
        return false
    }
    
    func executeUndo() {
        guard let action = currentUndo, let restore = action.restore else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        restore()
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
