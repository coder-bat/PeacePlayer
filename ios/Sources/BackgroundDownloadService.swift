//
//  BackgroundDownloadService.swift
//  YTAudioPlayer
//
//  Background download handling using URLSession
//

import Foundation
import Combine
import CoreData

protocol BackgroundDownloadDelegate: AnyObject {
    func downloadDidProgress(videoId: String, progress: Double)
    func downloadDidComplete(videoId: String, fileURL: URL)
    func downloadDidFail(videoId: String, error: Error)
}

class BackgroundDownloadService: NSObject {
    static let shared = BackgroundDownloadService()

    weak var delegate: BackgroundDownloadDelegate?

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
            print("🗑️ Deleted downloaded track from Core Data: \(videoId)")
        } catch {
            print("❌ Failed to delete downloaded track: \(error)")
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

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.downloadDidProgress(videoId: videoId, progress: progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let videoId = downloadTask.taskDescription,
              let task = activeDownloads[videoId] else { return }

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

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.downloadDidComplete(videoId: videoId, fileURL: permanentURL)
            }

            print("✅ Download complete: \(task.track.title)")

        } catch {
            downloadQueue.async { [weak self] in
                self?.activeDownloads.removeValue(forKey: videoId)
            }

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

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.downloadDidFail(videoId: videoId, error: error)
            }

            print("❌ Download failed: \(videoId) - \(error.localizedDescription)")
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
