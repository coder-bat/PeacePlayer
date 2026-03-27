//
//  DownloadManager.swift
//  YTAudioPlayer
//
//  Central download queue with progress tracking
//

import Foundation
import Combine
import CoreData

// Bridge class to connect BackgroundDownloadService to DownloadManager
class DownloadProgressDelegate: NSObject, BackgroundDownloadDelegate {
    private weak var manager: DownloadManager?

    init(manager: DownloadManager) {
        self.manager = manager
    }

    func downloadDidProgress(videoId: String, progress: Double) {
        manager?.handleDownloadProgress(trackId: videoId, progress: progress)
    }

    func downloadDidComplete(videoId: String, fileURL: URL) {
        manager?.handleDownloadComplete(trackId: videoId, fileURL: fileURL)
    }

    func downloadDidFail(videoId: String, error: Error) {
        manager?.handleDownloadError(trackId: videoId, error: error)
    }
}

struct DownloadTask: Identifiable {
    let id = UUID()
    let track: Track
    var progress: Double = 0.0
    var status: DownloadStatus = .pending
    var error: String?
    var completionTime: Date?
    
    enum DownloadStatus: Equatable {
        case pending
        case downloading
        case converting
        case completed
        case failed(String)
        
        var description: String {
            switch self {
            case .pending: return "Waiting..."
            case .downloading: return "Downloading..."
            case .converting: return "Converting..."
            case .completed: return "Completed"
            case .failed(let msg): return "Failed: \(msg)"
            }
        }
        
        var isActive: Bool {
            self == .downloading || self == .converting
        }
        
        var isFinished: Bool {
            if case .completed = self { return true }
            if case .failed = self { return true }
            return false
        }
    }
}

class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var activeDownloads: [DownloadTask] = []
    @Published var completedDownloads: [DownloadTask] = []
    @Published var isDownloading = false
    @Published var showDownloadQueue = false

    private var downloadQueue: [DownloadTask] = []
    private var currentTask: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private let maxConcurrentDownloads = 1

    // Serial queue for thread-safe state mutations
    private let stateQueue = DispatchQueue(label: "com.ytaudio.downloadstate", qos: .utility)

    private init() {}
    
    // MARK: - Public Methods
    
    func download(_ track: Track) {
        // Check if already in queue
        if activeDownloads.contains(where: { $0.track.videoId == track.videoId }) ||
           downloadQueue.contains(where: { $0.track.videoId == track.videoId }) {
            return
        }
        
        // Check if already downloaded
        if isAlreadyDownloaded(track) {
            return
        }
        
        let task = DownloadTask(track: track)
        downloadQueue.append(task)
        
        processQueue()
    }
    
    func downloadMultiple(_ tracks: [Track]) {
        for track in tracks {
            download(track)
        }
    }
    
    func cancelDownload(id: UUID) {
        // Remove from queue
        downloadQueue.removeAll { $0.id == id }
        
        // Remove from active
        if let index = activeDownloads.firstIndex(where: { $0.id == id }) {
            let task = activeDownloads[index]
            if task.status.isActive {
                currentTask?.cancel()
                currentTask = nil
                isDownloading = false
            }
            activeDownloads.remove(at: index)
            processQueue()
        }
    }
    
    func retryDownload(id: UUID) {
        if let task = completedDownloads.first(where: { $0.id == id }) {
            completedDownloads.removeAll { $0.id == id }
            download(task.track)
        }
    }
    
    func clearCompleted() {
        completedDownloads.removeAll()
    }

    func removeCompleted(id: UUID) {
        completedDownloads.removeAll { $0.id == id }
    }
    
    func clearAll() {
        currentTask?.cancel()
        currentTask = nil
        downloadQueue.removeAll()
        activeDownloads.removeAll()
        completedDownloads.removeAll()
        isDownloading = false
    }
    
    // MARK: - Query Methods
    
    func taskForTrack(_ track: Track) -> DownloadTask? {
        // Check active downloads
        if let task = activeDownloads.first(where: { $0.track.videoId == track.videoId }) {
            return task
        }
        // Check queue
        if let task = downloadQueue.first(where: { $0.track.videoId == track.videoId }) {
            return task
        }
        // Check completed (recent)
        return completedDownloads.first(where: { $0.track.videoId == track.videoId })
    }
    
    func isDownloading(_ track: Track) -> Bool {
        activeDownloads.contains(where: { $0.track.videoId == track.videoId }) ||
        downloadQueue.contains(where: { $0.track.videoId == track.videoId })
    }
    
    func cancelDownload(for track: Track) {
        // Find and cancel
        if let task = activeDownloads.first(where: { $0.track.videoId == track.videoId }) {
            cancelDownload(id: task.id)
        } else if let task = downloadQueue.first(where: { $0.track.videoId == track.videoId }) {
            downloadQueue.removeAll { $0.id == task.id }
        }
    }

    /// Delete a downloaded track by videoId (removes from Core Data and file system)
    func deleteDownload(videoId: String) {
        // Remove from Core Data
        BackgroundDownloadService.shared.deleteDownloadedTrack(videoId: videoId)

        // Remove local file
        AudioFileManager.shared.deleteLocalFile(videoId: videoId)

        // Remove from completed downloads if present
        completedDownloads.removeAll { $0.track.videoId == videoId }
    }

    // MARK: - Private Methods
    
    private func processQueue() {
        guard !isDownloading, !downloadQueue.isEmpty else { return }
        
        isDownloading = true
        let task = downloadQueue.removeFirst()
        
        var activeTask = task
        activeTask.status = .downloading
        activeDownloads.append(activeTask)
        
        performDownload(activeTask)
    }
    
    private var progressTimer: Timer?
    private var downloadDelegate: DownloadProgressDelegate?

    private func performDownload(_ task: DownloadTask) {
        // Start with a small progress to show activity
        updateProgress(for: task.id, progress: 0.05)

        // Get stream URL first, then download to local storage
        currentTask = APIService.shared.getStreamUrl(videoId: task.track.videoId)
            .sink(
                receiveCompletion: { [weak self] completion in
                    switch completion {
                    case .failure(let error):
                        self?.handleDownloadFailure(task.id, error: "\(error)")
                        self?.isDownloading = false
                        self?.processQueue()
                    case .finished:
                        break
                    }
                },
                receiveValue: { [weak self] streamInfo in
                    guard let self = self else { return }

                    // Create delegate to track progress
                    let delegate = DownloadProgressDelegate(manager: self)
                    self.downloadDelegate = delegate
                    BackgroundDownloadService.shared.delegate = delegate

                    // Start actual download to phone storage
                    BackgroundDownloadService.shared.download(track: task.track, streamUrl: streamInfo.streamUrl)
                }
            )
    }

    func handleDownloadProgress(trackId: String, progress: Double) {
        // Thread-safe access to activeDownloads
        stateQueue.async { [weak self] in
            guard let self = self,
                  let index = self.activeDownloads.firstIndex(where: { $0.track.videoId == trackId }) else {
                return
            }
            let taskId = self.activeDownloads[index].id
            self.updateProgress(for: taskId, progress: progress)
        }
    }

    func handleDownloadComplete(trackId: String, fileURL: URL) {
        // Thread-safe access to activeDownloads
        stateQueue.async { [weak self] in
            guard let self = self,
                  let index = self.activeDownloads.firstIndex(where: { $0.track.videoId == trackId }) else {
                return
            }
            let taskId = self.activeDownloads[index].id
            let track = self.activeDownloads[index].track

            // Save to Core Data (can be done on background queue)
            self.saveDownloadToCoreData(track: track, fileURL: fileURL)

            self.handleDownloadSuccess(taskId, path: fileURL.path)
            self.isDownloading = false
            self.processQueue()
        }
    }

    func handleDownloadError(trackId: String, error: Error) {
        // Thread-safe access to activeDownloads
        stateQueue.async { [weak self] in
            guard let self = self,
                  let index = self.activeDownloads.firstIndex(where: { $0.track.videoId == trackId }) else {
                return
            }
            let taskId = self.activeDownloads[index].id
            self.handleDownloadFailure(taskId, error: error.localizedDescription)
            self.isDownloading = false
            self.processQueue()
        }
    }

    private func saveDownloadToCoreData(track: Track, fileURL: URL) {
        // Use a background context for Core Data operations
        let context = PersistenceController.shared.backgroundContext

        context.performAndWait {
            do {
                // Fetch existing track or create new one (fetch-or-create pattern)
                let cdTrack: CDTrack
                let trackRequest: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                trackRequest.predicate = NSPredicate(format: "videoId == %@", track.videoId)
                trackRequest.fetchLimit = 1

                if let existingTrack = try context.fetch(trackRequest).first {
                    // Use existing track
                    cdTrack = existingTrack
                    print("📀 Using existing CDTrack: \(track.title)")
                } else {
                    // Create new track
                    cdTrack = CDTrack(context: context)
                    cdTrack.videoId = track.videoId
                    cdTrack.title = track.title
                    cdTrack.artists = track.artists
                    cdTrack.album = track.album
                    cdTrack.durationSeconds = Int32(track.durationSeconds)
                    cdTrack.thumbnailURLs = track.thumbnails.map { $0.url.absoluteString }
                    cdTrack.isExplicit = track.isExplicit
                    cdTrack.videoType = track.videoType
                    cdTrack.createdAt = Date()
                    cdTrack.isLiked = false
                    print("📀 Created new CDTrack: \(track.title)")
                }

                // Check if download record already exists
                let downloadRequest: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
                downloadRequest.predicate = NSPredicate(format: "track.videoId == %@", track.videoId)
                downloadRequest.fetchLimit = 1

                if let existingDownload = try context.fetch(downloadRequest).first {
                    // Update existing download record
                    existingDownload.localPath = fileURL.path
                    existingDownload.fileSize = Int64((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0)
                    existingDownload.downloadedAt = Date()
                    print("📀 Updated existing CDDownloadedTrack: \(track.title)")
                } else {
                    // Create new downloaded track record
                    let downloadedTrack = CDDownloadedTrack(context: context)
                    downloadedTrack.localPath = fileURL.path
                    downloadedTrack.fileSize = Int64((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0)
                    downloadedTrack.mimeType = "audio/mp4"
                    downloadedTrack.quality = "high"
                    downloadedTrack.downloadedAt = Date()
                    downloadedTrack.track = cdTrack
                    print("📀 Created new CDDownloadedTrack: \(track.title)")
                }

                try context.save()
                print("✅ Saved download to Core Data: \(track.title)")
            } catch {
                print("❌ Failed to save download to Core Data: \(error)")
                context.rollback()
            }
        }
    }
    
    private func updateProgress(for id: UUID, progress: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let index = self.activeDownloads.firstIndex(where: { $0.id == id }) {
                var task = self.activeDownloads[index]
                task.progress = progress
                
                // Switch to converting at 80%
                if task.progress >= 0.8 && task.status == .downloading {
                    task.status = .converting
                }
                
                // Trigger array update on main thread
                self.activeDownloads[index] = task
            }
        }
    }
    
    private func handleDownloadSuccess(_ id: UUID, path: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let index = self.activeDownloads.firstIndex(where: { $0.id == id }) {
                var task = self.activeDownloads[index]
                task.progress = 1.0
                task.status = .completed
                task.completionTime = Date()

                // Pre-warm waveform cache for this downloaded track
                WaveformService.shared.prefetch(videoId: task.track.videoId)

                self.activeDownloads.remove(at: index)
                self.completedDownloads.append(task)

                HapticManager.success()
            }
        }
    }
    
    private func handleDownloadFailure(_ id: UUID, error: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let index = self.activeDownloads.firstIndex(where: { $0.id == id }) {
                var task = self.activeDownloads[index]
                task.status = .failed(error)
                task.completionTime = Date()
                
                self.activeDownloads.remove(at: index)
                self.completedDownloads.append(task)
                
                HapticManager.error()
            }
        }
    }
    
    func isAlreadyDownloaded(_ track: Track) -> Bool {
        // Check Core Data for existing download
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "track.videoId == %@", track.videoId)

        do {
            let count = try context.count(for: request)
            return count > 0
        } catch {
            print("❌ Error checking if track is downloaded: \(error)")
            return false
        }
    }
}
