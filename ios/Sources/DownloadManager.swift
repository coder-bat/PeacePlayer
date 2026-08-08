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

    private init() {
        // C-1 fix: subscribe to BackgroundDownloadService's Combine publishers
        // so download completion / error events are delivered reliably even when
        // iOS relaunches the app to deliver a background URLSession event.
        // The previous weak-delegate pattern silently dropped these events
        // because DownloadManager was lazily initialized *after* the completion
        // fired during the relaunch.
        BackgroundDownloadService.shared.completions
            .receive(on: stateQueue)
            .sink { [weak self] completion in
                self?.handleDownloadComplete(trackId: completion.videoId, fileURL: completion.fileURL)
            }
            .store(in: &cancellables)

        BackgroundDownloadService.shared.errors
            .receive(on: stateQueue)
            .sink { [weak self] (videoId, error) in
                self?.handleDownloadError(trackId: videoId, error: error)
            }
            .store(in: &cancellables)

        BackgroundDownloadService.shared.progressPublisher
            .receive(on: stateQueue)
            .sink { [weak self] (videoId, progress) in
                self?.handleDownloadProgress(trackId: videoId, progress: progress)
            }
            .store(in: &cancellables)
    }
    
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
        HapticManager.light()
        
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
    // S13: stalled-watchdog state. `lastObservedProgress` is updated
    // every time `handleDownloadProgress` fires; the watchdog timer
    // ticks every 5s and compares it to the previously-observed value.
    // Two consecutive unchanged ticks (10s of zero progress) means the
    // download is stuck — we surface a user-visible error and mark the
    // task as failed.
    //
    // S17-H / DOWNLOAD-CDN-FIX (2026-08-08): the new flow goes
    // POST /download (server-side YouTube fetch + ffmpeg, ~5-10s)
    // followed by GET /library/{filename} (the file body, ~50ms).
    // The POST phase shows 0% progress for the full duration, so
    // the original 10s watchdog would fire incorrectly. We extend
    // the threshold to 6 ticks (30s) to cover the worst-case
    // server-side pipeline.
    private var lastObservedProgress: Double = 0
    private var lastObservedTaskId: UUID?
    private var stalledTickCount: Int = 0
    private let stallTickThreshold = 6   // 6 ticks × 5s = 30s stalled
    private let stallTickInterval: TimeInterval = 5

    private func performDownload(_ task: DownloadTask) {
        // Start with a small progress to show activity
        updateProgress(for: task.id, progress: 0.05)

        // S13: reset watchdog state for this new task.
        lastObservedProgress = 0.05
        lastObservedTaskId = task.id
        stalledTickCount = 0
        startStallWatchdog(taskId: task.id)

        // S17-H / DOWNLOAD-CDN-FIX (2026-08-08): go through the
        // backend's POST /download endpoint instead of pulling the
        // streamUrl directly. The previous flow did:
        //   1. GET /stream → /fast → 302 to YouTube format 18
        //   2. URLSession.downloadTask(with: streamUrl)
        //   3. URLSession follows 302, hits YouTube CDN
        //   4. YouTube throttles, download stalls at ~1.8MB
        //   5. S13 watchdog fires at 10s → "Download failed"
        //
        // New flow:
        //   1. POST /download (server-side YouTube fetch via
        //      Range chunks, ~5-10s, then ffmpeg convert)
        //   2. Response includes downloadUrl = /library/{filename}
        //   3. URLSession.downloadTask(with: downloadUrl) → file
        //      body (3-30MB, no YouTube in the path, no throttling)
        //   4. Save to local AudioFileManager
        currentTask = APIService.shared.downloadTrack(task.track)
            .sink(
                receiveCompletion: { [weak self] completion in
                    switch completion {
                    case .failure(let error):
                        // POST /download failed → stop the watchdog
                        // and surface the error.
                        DispatchQueue.main.async { [weak self] in
                            self?.progressTimer?.invalidate()
                            self?.progressTimer = nil
                        }
                        self?.handleDownloadFailure(task.id, error: "POST /download: \(error)")
                        self?.isDownloading = false
                        self?.processQueue()
                    case .finished:
                        break
                    }
                },
                receiveValue: { [weak self] response in
                    guard let self = self else { return }
                    // Mark the prep phase done so the watchdog
                    // sees forward progress. The actual download
                    // (the GET) starts at progress = 0.10.
                    self.updateProgress(for: task.id, progress: 0.10)
                    self.lastObservedProgress = 0.10
                    self.stalledTickCount = 0

                    // If the backend couldn't produce a
                    // downloadUrl (shouldn't happen with the
                    // current /download implementation), fall
                    // back to the streamUrl flow.
                    guard let downloadUrl = response.downloadUrl else {
                        self.handleDownloadFailure(
                            task.id,
                            error: "backend /download returned no downloadUrl"
                        )
                        self.isDownloading = false
                        self.processQueue()
                        return
                    }

                    // Build the absolute URL. /library/{filename}
                    // is on the same backend as /stream, so we use
                    // baseURL to resolve it.
                    let absoluteUrl = APIService.shared.baseURL + downloadUrl
                    let urlWithToken = self.appendToken(to: absoluteUrl)

                    // Create delegate to track progress
                    let delegate = DownloadProgressDelegate(manager: self)
                    self.downloadDelegate = delegate
                    BackgroundDownloadService.shared.delegate = delegate

                    // Start actual download to phone storage
                    BackgroundDownloadService.shared.download(
                        track: task.track,
                        streamUrl: urlWithToken
                    )
                }
            )
    }

    /// Append the current iOS auth token to a downloadUrl that
    /// doesn't already carry one. /library is gated by the same
    /// JWT the rest of the backend uses; URLSession's
    /// Authorization header survives the 302, so the token in
    /// the query is a defense-in-depth fallback (the iOS app
    /// already sends the Bearer header).
    private func appendToken(to url: String) -> String {
        guard let token = KeychainHelper.shared.read("session_token") else {
            return url
        }
        if url.contains("token=") { return url }
        let sep = url.contains("?") ? "&" : "?"
        return "\(url)\(sep)token=\(token)"
    }

    // S13: Start (or restart) the stalled-watchdog timer. Cancels any
    // existing timer first so we don't double-fire.
    private func startStallWatchdog(taskId: UUID) {
        progressTimer?.invalidate()
        stalledTickCount = 0
        progressTimer = Timer.scheduledTimer(
            withTimeInterval: stallTickInterval,
            repeats: true
        ) { [weak self] _ in
            self?.stallWatchdogTick(taskId: taskId)
        }
    }

    // S13: Each tick, compare the latest known progress with the
    // previously-known value. If they're equal AND the task is still
    // in activeDownloads, count this as a stall tick. After 2 stall
    // ticks (10s) we surface a toast and fail the task.
    private func stallWatchdogTick(taskId: UUID) {
        // Verify the task is still active (not completed/failed/cancelled
        // via another path).
        guard activeDownloads.contains(where: { $0.id == taskId }) else {
            progressTimer?.invalidate()
            progressTimer = nil
            return
        }

        if let currentProgress = activeDownloads.first(where: { $0.id == taskId })?.progress,
           currentProgress == lastObservedProgress,
           currentProgress < 1.0 {
            stalledTickCount += 1
            if stalledTickCount >= stallTickThreshold {
                progressTimer?.invalidate()
                progressTimer = nil
                let title = activeDownloads.first(where: { $0.id == taskId })?.track.title ?? "Track"
                ErrorHandler.shared.show(.downloadFailed("\(title) stalled — no progress for 10 seconds."))
                handleDownloadFailure(taskId, error: "Stalled: no progress for 10s")
                isDownloading = false
                processQueue()
            }
        } else {
            // Progress advanced — reset the stall counter.
            stalledTickCount = 0
            lastObservedProgress = activeDownloads.first(where: { $0.id == taskId })?.progress ?? 0
        }
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

            // S13: real progress arrived → reset the stalled-watchdog.
            // The stall counter only increments when progress is unchanged
            // across timer ticks; normal progression keeps it at zero.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lastObservedProgress = progress
                self.stalledTickCount = 0
            }
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

            // S13: a successful download means the watchdog is no longer
            // needed; cancel it so we don't false-positive-stall the next
            // task that re-uses the timer slot.
            DispatchQueue.main.async { [weak self] in
                self?.progressTimer?.invalidate()
                self?.progressTimer = nil
            }

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

            // S13: failed download → stop the watchdog.
            DispatchQueue.main.async { [weak self] in
                self?.progressTimer?.invalidate()
                self?.progressTimer = nil
            }

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
        // C-5 fix: delegate to AudioFileManager.isPlayable, which reconciles
        // the Core Data row with the on-disk file. Previously this only
        // checked Core Data, so a stale row (file deleted via Files.app)
        // would falsely report the track as downloaded.
        return AudioFileManager.shared.isPlayable(
            videoId: track.videoId,
            context: PersistenceController.shared.viewContext
        )
    }
}
