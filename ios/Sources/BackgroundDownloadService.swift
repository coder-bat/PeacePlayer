//
//  BackgroundDownloadService.swift
//  YTAudioPlayer
//
//  Background download handling using URLSession
//

import Foundation
import Combine
import CoreData

/// Legacy delegate protocol — kept for backwards compatibility.
/// Prefer subscribing to `completions` / `errors` / `progress` publishers
/// since Combine subjects survive even when the listener is lazily initialized
/// after a background relaunch (which is when downloads actually complete).
protocol BackgroundDownloadDelegate: AnyObject {
    func downloadDidProgress(videoId: String, progress: Double)
    func downloadDidComplete(videoId: String, fileURL: URL)
    func downloadDidFail(videoId: String, error: Error)
}

/// Download completion event (C-1 fix: reliably delivered via Combine subject)
struct DownloadCompletion {
    let videoId: String
    let fileURL: URL
}

class BackgroundDownloadService: NSObject {
    static let shared = BackgroundDownloadService()

    /// Legacy weak delegate — kept for any callers still wiring up the old way.
    /// New code should subscribe to the publishers below.
    weak var delegate: BackgroundDownloadDelegate?

    // MARK: - C-1 fix: Combine publishers survive iOS-launched app relaunch
    // The weak delegate pattern silently dropped events when iOS relaunched the
    // app to deliver background download completions (DownloadManager was a
    // singleton not yet wired). PassthroughSubject delivers to any active
    // subscribers, even if they subscribed in a later scene phase.
    private let completionSubject = PassthroughSubject<DownloadCompletion, Never>()
    private let errorSubject = PassthroughSubject<(videoId: String, error: Error), Never>()
    private let progressSubject = PassthroughSubject<(videoId: String, progress: Double), Never>()

    var completions: AnyPublisher<DownloadCompletion, Never> {
        completionSubject.eraseToAnyPublisher()
    }
    var errors: AnyPublisher<(videoId: String, error: Error), Never> {
        errorSubject.eraseToAnyPublisher()
    }
    var progressPublisher: AnyPublisher<(videoId: String, progress: Double), Never> {
        progressSubject.eraseToAnyPublisher()
    }

    /// C-1 fix: stored handler for `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// Invoked once `urlSessionDidFinishEvents(forBackgroundURLSession:)` fires.
    private var backgroundCompletionHandler: (() -> Void)?

    func storeBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    private var session: URLSession!
    private var activeDownloads: [String: DownloadTask] = [:]
    private let downloadQueue = DispatchQueue(label: "com.ytaudio.downloads", qos: .utility)

    private struct DownloadTask {
        let videoId: String
        let track: Track
        let destinationURL: URL
        var progress: Double = 0
    }

    override private init() {
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: "com.ytaudio.background-download")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true

        // Performance optimizations for faster downloads
        config.timeoutIntervalForRequest = 60  // 1 minute for initial connection
        config.timeoutIntervalForResource = 600  // 10 minutes for complete download
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true

        // Increase network performance
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil  // Disable URL cache for streaming downloads

        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public Methods

    func download(track: Track, streamUrl: String) {
        downloadQueue.async { [weak self] in
            guard let self = self else { return }

            // Check if already downloading
            if self.activeDownloads[track.videoId] != nil {
                return
            }

            guard let url = URL(string: streamUrl) else {
                self.delegate?.downloadDidFail(videoId: track.videoId, error: DownloadError.invalidURL)
                return
            }

            let destinationURL = AudioFileManager.shared.localFileURL(for: track.videoId)

            let downloadTask = self.session.downloadTask(with: url)
            downloadTask.taskDescription = track.videoId

            let task = DownloadTask(
                videoId: track.videoId,
                track: track,
                destinationURL: destinationURL
            )

            self.activeDownloads[track.videoId] = task
            downloadTask.resume()

            print("🔽 Started download for: \(track.title)")
        }
    }

    func cancelDownload(videoId: String) {
        downloadQueue.async { [weak self] in
            guard let self = self else { return }

            session.getAllTasks { tasks in
                if let task = tasks.first(where: { $0.taskDescription == videoId }) {
                    task.cancel()
                }
            }

            self.activeDownloads.removeValue(forKey: videoId)
        }
    }

    func pauseDownload(videoId: String) {
        session.getAllTasks { tasks in
            if let task = tasks.first(where: { $0.taskDescription == videoId }) as? URLSessionDownloadTask {
                task.suspend()
            }
        }
    }

    func resumeDownload(videoId: String) {
        session.getAllTasks { tasks in
            if let task = tasks.first(where: { $0.taskDescription == videoId }) as? URLSessionDownloadTask {
                task.resume()
            }
        }
    }

    // MARK: - Query Methods

    func isDownloading(videoId: String) -> Bool {
        return activeDownloads[videoId] != nil
    }

    func downloadProgress(for videoId: String) -> Double {
        return activeDownloads[videoId]?.progress ?? 0
    }

    // MARK: - Cleanup

    func clearCompletedDownloads() {
        downloadQueue.async { [weak self] in
            self?.activeDownloads.removeAll()
        }
    }

    /// Delete a downloaded track from Core Data
    /// C-5 fix: also deletes the underlying file via AudioFileManager so
    /// deleteDownload is a true "remove from disk + Core Data" operation.
    /// Previously this only removed the row, leaving orphan files on disk.
    func deleteDownloadedTrack(videoId: String) {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "track.videoId == %@", videoId)

        do {
            let results = try context.fetch(request)
            for track in results {
                context.delete(track)
            }
            try context.save()
            // Also remove the on-disk file
            AudioFileManager.shared.deleteLocalFile(videoId: videoId)
            print("🗑️ Deleted downloaded track + file: \(videoId)")
        } catch {
            print("❌ Failed to delete downloaded track: \(error)")
        }
    }

    // MARK: - C-1 fix: bootstrap() — orphan recovery

    /// Scan the Downloads directory for files missing a Core Data row and
    /// surface them. Called from AppDelegate on launch.
    ///
    /// Best-effort recovery: we can't fully reconstruct track metadata (title,
    /// artist) from a bare .m4a, so this logs orphans for manual intervention
    /// rather than fabricating Core Data rows. If the user opens the app while
    /// the download is in flight, the new Combine-based completion path takes
    /// over and writes the row normally.
    func bootstrap() {
        downloadQueue.async { [weak self] in
            guard let self = self else { return }

            let files = AudioFileManager.shared.allDownloadedFiles()
            guard !files.isEmpty else { return }

            let context = PersistenceController.shared.viewContext
            var orphanCount = 0

            for file in files {
                let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
                request.predicate = NSPredicate(format: "track.videoId == %@", file.videoId)

                do {
                    let count = try context.count(for: request)
                    if count == 0 {
                        orphanCount += 1
                        print("⚠️ Orphan download detected: \(file.videoId) (\(file.size) bytes) — re-download to register in Library")
                    }
                } catch {
                    print("❌ Bootstrap scan error for \(file.videoId): \(error)")
                }
            }

            if orphanCount > 0 {
                print("📦 Bootstrap: \(orphanCount) orphan download(s) found in \(files.count) file(s)")
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate
extension BackgroundDownloadService: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let videoId = downloadTask.taskDescription,
              activeDownloads[videoId] != nil else { return }

        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        downloadQueue.async { [weak self] in
            self?.activeDownloads[videoId]?.progress = progress
        }

        // C-1 fix: emit to Combine subject in addition to weak delegate
        progressSubject.send((videoId, progress))

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.downloadDidProgress(videoId: videoId, progress: progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let videoId = downloadTask.taskDescription,
              let task = activeDownloads[videoId] else { return }

        // S17-H / DOWNLOAD-STATUS-CHECK (2026-08-08): URLSession
        // calls didFinishDownloadingTo for ANY 2xx-5xx response,
        // including 401 (25 bytes of {"detail":"unauthorized"})
        // and 404 (small HTML page). Without this check, the
        // BackgroundDownloadService would treat a 25-byte error
        // JSON as a valid audio file, move it to the permanent
        // location, and report "Download complete" — leaving the
        // user with a corrupt file in their library and the
        // DownloadManager thinking everything is fine.
        //
        // Symptom (reported by user 2026-08-08): "when i
        // downloaded from search, it said download success but
        // only 25 bytes download". Backend log showed a
        // /library/{filename} → 401 (25 bytes) for that exact
        // request. Root cause was URLSession not picking up the
        // Bearer token in the Authorization header, so the
        // appendToken-in-query fallback should have kicked in but
        // didn't (likely stale keychain on a relaunched session).
        //
        // This check makes the failure visible instead of silent.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            // Read the error body so we can surface a useful
            // message instead of a generic "Download failed".
            var errorBody = ""
            if let data = try? Data(contentsOf: location) {
                errorBody = String(data: data, encoding: .utf8) ?? "<binary>"
                if errorBody.count > 200 { errorBody = String(errorBody.prefix(200)) + "..." }
            }
            // The "downloaded" file is actually a 25-byte error
            // body. Don't move it to the permanent location.
            try? FileManager.default.removeItem(at: location)
            downloadQueue.async { [weak self] in
                self?.activeDownloads.removeValue(forKey: videoId)
            }
            let err = NSError(
                domain: "BackgroundDownloadService",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "Download failed: HTTP \(http.statusCode) \(errorBody)"
                ]
            )
            errorSubject.send((videoId, err))
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.downloadDidFail(videoId: videoId, error: err)
            }
            print("❌ Download failed: \(videoId) HTTP \(http.statusCode) — \(errorBody)")
            return
        }

        do {
            // Move file to permanent location
            let permanentURL = try AudioFileManager.shared.moveDownloadedFile(
                from: location,
                to: videoId,
                extension: "m4a"
            )

            downloadQueue.async { [weak self] in
                self?.activeDownloads.removeValue(forKey: videoId)
            }

            // C-1 fix: emit to Combine subject in addition to weak delegate
            completionSubject.send(DownloadCompletion(videoId: videoId, fileURL: permanentURL))

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.downloadDidComplete(videoId: videoId, fileURL: permanentURL)
            }

            print("✅ Download complete: \(task.track.title)")

        } catch {
            downloadQueue.async { [weak self] in
                self?.activeDownloads.removeValue(forKey: videoId)
            }

            errorSubject.send((videoId, error))

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.downloadDidFail(videoId: videoId, error: error)
            }

            print("❌ Failed to save download: \(error)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let videoId = task.taskDescription else { return }

        if let error = error {
            downloadQueue.async { [weak self] in
                self?.activeDownloads.removeValue(forKey: videoId)
            }

            errorSubject.send((videoId, error))

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.downloadDidFail(videoId: videoId, error: error)
            }

            print("❌ Download failed: \(videoId) - \(error.localizedDescription)")
        }
    }

    // C-1 fix: deliver stored background completion handler when iOS tells us
    // the URLSession is done delivering events for a background session.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - Errors
enum DownloadError: Error {
    case invalidURL
    case fileMoveFailed
    case invalidResponse
    case cancelled
}
