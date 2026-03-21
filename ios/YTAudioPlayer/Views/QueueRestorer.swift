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
    private let dataManager = DataManager.shared
    
    private init() {}
    
    /// Attempt to restore the queue with fresh stream URLs
    func restoreQueue() -> AnyPublisher<[QueueItem], Error> {
        let snapshots = dataManager.loadQueue()
        guard !snapshots.isEmpty else {
            return Just([]).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
        
        // Filter out stale entries (older than 1 hour)
        let freshSnapshots = snapshots.filter { 
            Date().timeIntervalSince($0.savedAt) < 3600 
        }
        
        if freshSnapshots.isEmpty {
            dataManager.clearSavedQueue()
            return Just([]).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
        
        isRestoring = true
        totalCount = freshSnapshots.count
        restoredCount = 0
        
        // Fetch stream URLs for each track
        let publishers = freshSnapshots.map { snapshot in
            fetchStreamUrl(for: snapshot)
        }
        
        return Publishers.MergeMany(publishers)
            .collect()
            .map { items in
                // Filter out nils and maintain original order
                items.compactMap { $0 }
            }
            .setFailureType(to: Error.self)
            .handleEvents(receiveCompletion: { [weak self] _ in
                self?.isRestoring = false
            })
            .eraseToAnyPublisher()
    }
    
    /// Restore and immediately start playback from last position
    func restoreAndResume() -> AnyPublisher<Void, Error> {
        let (trackId, progress) = dataManager.loadLastPlaybackState()
        
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
    
    private func fetchStreamUrl(for snapshot: QueueItemSnapshot) -> AnyPublisher<QueueItem?, Never> {
        APIService.shared.getStreamUrl(videoId: snapshot.videoId)
            .map { streamInfo -> QueueItem? in
                QueueItem(
                    track: snapshot.track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
            }
            .catch { _ -> Just<QueueItem?> in
                Just(nil)
            }
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.restoredCount += 1
            })
            .eraseToAnyPublisher()
    }
    
    /// Shows a restore prompt if there's a saved queue
    func shouldShowRestorePrompt() -> Bool {
        let snapshots = dataManager.loadQueue()
        let freshCount = snapshots.filter { 
            Date().timeIntervalSince($0.savedAt) < 3600 
        }.count
        return freshCount > 0
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
                        DataManager.shared.clearSavedQueue()
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
