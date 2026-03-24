//
//  QueueRestorer.swift
//  YTAudioPlayer
//
//  Restores queue by re-fetching stream URLs for saved tracks
//

import Foundation
import SwiftUI
import Combine

/// Restores the playback queue from saved state
class QueueRestorer: ObservableObject {
    static let shared = QueueRestorer()

    @Published var isRestoring = false
    @Published var restoredCount = 0
    @Published var totalCount = 0

    var cancellables = Set<AnyCancellable>()
    private let queueManager = PlaybackQueueManager.shared

    private init() {}

    /// Attempt to restore the queue with fresh stream URLs
    func restoreQueue() -> AnyPublisher<[QueueItem], Error> {
        return Future { [weak self] promise in
            guard let self = self else {
                promise(.success([]))
                return
            }

            let savedItems = self.queueManager.loadQueue()
            guard !savedItems.isEmpty else {
                promise(.success([]))
                return
            }

            self.isRestoring = true
            self.totalCount = savedItems.count
            self.restoredCount = 0

            // Use the PlaybackQueueManager to restore with fresh stream URLs
            self.queueManager.restoreQueue { items in
                self.isRestoring = false
                promise(.success(items))
            }
        }.eraseToAnyPublisher()
    }

    /// Restore and immediately start playback from last position
    func restoreAndResume() -> AnyPublisher<Void, Error> {
        let (trackId, progress) = DataManager.shared.loadLastPlaybackState()

        return restoreQueue()
            .flatMap { items -> AnyPublisher<Void, Error> in
                guard !items.isEmpty else {
                    return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
                }

                // Find the last playing track
                if let trackId = trackId,
                   let index = items.firstIndex(where: { $0.track.videoId == trackId }) {
                    // Resume from saved position
                    PlayerState.shared.queue = items
                    PlayerState.shared.currentIndex = index
                    PlayerState.shared.playQueue(at: index)

                    // Seek to saved position after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        PlayerState.shared.seek(to: progress)
                    }
                } else {
                    // Just load the queue, don't auto-play
                    PlayerState.shared.queue = items
                }

                return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    /// Shows a restore prompt if there's a saved queue
    func shouldShowRestorePrompt() -> Bool {
        let savedItems = queueManager.loadQueue()
        return !savedItems.isEmpty
    }
}

// MARK: - SwiftUI View Extension

struct QueueRestorePrompt: View {
    @StateObject private var restorer = QueueRestorer.shared
    @State private var isRestoring = false
    @State private var showError = false
    var onDismiss: () -> Void
    
    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)
            
            Text("Resume Playback?")
                .font(.title2.bold())
            
            Text("You have a saved queue from your last session.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            if isRestoring {
                ProgressView()
                    .scaleEffect(1.2)
                    .padding()
            } else {
                HStack(spacing: 12) {
                    Button("Start Fresh") {
                        PlaybackQueueManager.shared.clearSavedQueue()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Resume") {
                        restoreQueue()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 20)
        .padding(40)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Could not restore your queue. Please try again.")
        }
    }
    
    private func restoreQueue() {
        isRestoring = true
        
        restorer.restoreAndResume()
            .sink(receiveCompletion: { [self] completion in
                self.isRestoring = false
                if case .failure = completion {
                    self.showError = true
                } else {
                    self.onDismiss()
                }
            }, receiveValue: { _ in })
            .store(in: &restorer.cancellables)
    }
}
