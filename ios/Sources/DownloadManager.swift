//
//  DownloadManager.swift
//  YTAudioPlayer
//
//  Central download queue with progress tracking
//

import Foundation
import Combine
import CoreData

// 2026-08-13: removed `DownloadProgressDelegate`. It was the
// bridge between BackgroundDownloadService's legacy weak-delegate
// API and DownloadManager. The Combine subscription in
// `DownloadManager.init` is now the single source of truth for
// completion / error / progress events — the legacy path was
// duplicate-delivering every event. Nothing else in the app
// referenced this class.

// v1.9.0: DownloadSource — distinguishes user-initiated downloads
// from system-initiated ones (auto-cycle, refresh). The
// SmartLibraryManager uses this to fix the tier-upgrade bug
// (gap #2): when a user manually re-downloads a previously
// auto-downloaded track, the track should be promoted from the
// .auto tier (14d cleanup) to the .manual tier (60d cleanup).
//
// Callers pass the source explicitly:
//   - `source: .user`     — user tapped the download button in
//                          any context menu, row, sheet, etc.
//   - `source: .auto`     — SmartLibraryManager auto-download
//                          cycle, candidates are tier-marked
//                          after successful download.
//   - `source: .refresh`  — SmartLibraryManager Refresh Downloads
//                          flow, clears library first then
//                          re-derives. The new tracks are
//                          tier-marked .auto (14d applies) so the
//                          user can heart them for permanent
//                          retention.
enum DownloadSource: String {
    case user
    case auto
    case refresh
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

    // 2026-08-12: was `private var downloadQueue` — exposed
    // as @Published so WidgetSyncService can observe the
    // pending count and show "X +N more" in the widget when
    // tracks are queued. The internal API is unchanged
    // (append/removeFirst/removeAll); only the visibility
    // and publisher semantics changed.
    @Published private(set) var downloadQueue: [DownloadTask] = []
    private var currentTask: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private let maxConcurrentDownloads = 1

    // 2026-08-13: removed `stateQueue`. The old
    // `.receive(on: stateQueue)` Combine pipeline mutated
    // @Published arrays from the wrong thread (see init
    // comment for the full story). Everything is now on
    // main; CoreData work uses `context.performAndWait`'s
    // own private queue.

    private init() {
        // 2026-08-13: switched the receive scheduler from
        // `stateQueue` to `.main`. Three reasons:
        //
        // 1. **Stops the second-download hang.** With
        //    `.receive(on: stateQueue)`, the first download's
        //    completion delivered `handleDownloadComplete` on
        //    stateQueue, which then called `processQueue()` on
        //    stateQueue. `processQueue` mutates `@Published`
        //    arrays (`activeDownloads`, `downloadQueue`,
        //    `isDownloading`) — and those mutations happened on
        //    stateQueue, not main. Meanwhile, main was running
        //    `handleDownloadSuccess` for the just-completed
        //    task, which also reads + mutates `activeDownloads`
        //    (`activeDownloads.remove(at: 0)`). The two threads
        //    hit the same `Array` concurrently. Swift `Array`
        //    is not thread-safe — concurrent mutation can
        //    corrupt its internal storage, and the next
        //    `firstIndex(where:)` call on the corrupted array
        //    spins or returns a wrong element, freezing the
        //    main thread. First download dodged this because
        //    its `processQueue` was on main (called from UI).
        //    Second download was the one that hung.
        //
        // 2. **Stops the silent stall watchdog.** The Timer
        //    created by `startStallWatchdog` was registered on
        //    whatever run loop the calling thread had — for
        //    the second download, that was stateQueue (a GCD
        //    worker). `Timer.scheduledTimer` on a GCD thread
        //    either adds to a non-existent run loop (no-op) or
        //    fires on the wrong loop, so the 30s stall
        //    watchdog never tripped. With `.receive(on:
        //    .main)`, `performDownload` and its Timer
        //    creation land on main → the watchdog actually
        //    fires.
        //
        // 3. **Kills the duplicate `handleDownloadComplete`
        //    call.** The C-1 fix added the Combine path so
        //    background-relaunch completions wouldn't be
        //    lost, but the legacy weak-delegate path was
        //    still wired. Every completion fired
        //    `handleDownloadComplete` twice (once from the
        //    Combine sink, once from the main-thread
        //    `delegate?.downloadDidComplete` call). The second
        //    call did a redundant CoreData save + set
        //    `isDownloading = false` while a fresh download
        //    was starting, racing with `processQueue`'s
        //    `isDownloading = true`. The Combine path alone
        //    covers both foreground and background-relaunch
        //    cases (the C-1 fix's whole point), so the legacy
        //    delegate is now unused — see the removal of
        //    `BackgroundDownloadService.shared.delegate =
        //    delegate` in `performDownload` below.
        //
        // The CoreData save inside `handleDownloadComplete`
        // already uses `context.performAndWait`, which has
        // its own private queue — so we don't lose anything
        // by moving the surrounding orchestration to main.
        BackgroundDownloadService.shared.completions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                self?.handleDownloadComplete(trackId: completion.videoId, fileURL: completion.fileURL)
            }
            .store(in: &cancellables)

        BackgroundDownloadService.shared.errors
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (videoId, error) in
                self?.handleDownloadError(trackId: videoId, error: error)
            }
            .store(in: &cancellables)

        BackgroundDownloadService.shared.progressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (videoId, progress) in
                self?.handleDownloadProgress(trackId: videoId, progress: progress)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods

    /// Queue a track for download.
    /// - Parameters:
    ///   - track: the track to download
    ///   - source: who initiated the download. Defaults to
    ///     `.user` so the safe path is the default for any
    ///     caller that hasn't been audited. See `DownloadSource`
    ///     for the per-source semantics.
    func download(_ track: Track, source: DownloadSource = .user) {
        // v1.9.0: tier-upgrade fix (gap #2). When a user
        // explicitly downloads a track that was previously
        // auto-downloaded, promote it from the .auto tier
        // (14d cleanup) to .manual (60d cleanup) by removing
        // it from SmartLibraryManager's autoDownloadedVideoIds
        // set. This MUST run before the isAlreadyDownloaded
        // short-circuit below — that early return would skip
        // the promotion and the track would stay tier=.auto
        // for its next cleanup check, even though the user
        // just took an explicit action.
        //
        // SmartLibraryManager is @MainActor-isolated;
        // DownloadManager is not, so we hop to the main
        // actor via Task. The hop is fine because the
        // subsequent isAlreadyDownloaded check + queue
        // append are local (in-memory) operations and
        // don't race with the prune — the prune only
        // mutates a Set + writes UserDefaults, both of
        // which can happen any time before the actual
        // download completes. The download itself is
        // async via BackgroundDownloadService, so by the
        // time the file is on disk the prune has long
        // since run.
        if source == .user {
            let videoId = track.videoId
            Task { @MainActor in
                if SmartLibraryManager.shared.autoDownloadedVideoIds.contains(videoId) {
                    SmartLibraryManager.shared.removeFromAutoSet(videoId: videoId)
                }
            }
        }

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

    /// Bulk variant. The source applies to every track in the
    /// batch — callers that need mixed sources should call
    /// `download(_:source:)` per track.
    func downloadMultiple(_ tracks: [Track], source: DownloadSource = .user) {
        for track in tracks {
            download(track, source: source)
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

        // 2026-08-12: post .downloadDeleted so SmartLibraryManager
        // can drop the videoId from its autoDownloadedVideoIds
        // set. Without this, the set would grow unboundedly with
        // stale entries pointing at videoIds that no longer have
        // an on-disk file. The set is only used for tier lookup
        // (auto vs manual), so a stale entry would at worst
        // mis-classify a re-downloaded track — but it's tidier
        // to keep it accurate.
        NotificationCenter.default.post(
            name: .downloadDeleted,
            object: videoId
        )
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
    // 2026-08-13: removed `downloadDelegate: DownloadProgressDelegate?`.
    // The Combine subscription in `init` is now the single source of
    // truth for completion / error / progress events; the legacy
    // weak-delegate path was duplicate-delivering every event.
    // The `DownloadProgressDelegate` class at the top of this file
    // is kept around only as a no-op stub (it has no other
    // references) — see the comment at its declaration.
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

                    // 2026-08-13: removed the legacy
                    //   `BackgroundDownloadService.shared.delegate = delegate`
                    //   assignment. The Combine path (subscribed
                    //   in `init`) is the single source of truth
                    //   for completion / error / progress events.
                    //   The legacy weak-delegate path was
                    //   duplicate-delivering every event — see
                    //   the init comment for the full story.
                    //
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
        // S17-H / DOWNLOAD-STATUS-CHECK (2026-08-08): use the
        // SAME keychain key the rest of the app uses
        // ("peaceplayer.session_token", defined in APIService as
        // `authTokenKeychainKey` and used by AuthService/SyncService).
        // The earlier key "session_token" was a typo and read nil,
        // so the fallback token was never appended to the URL —
        // /library returned 401 (25 bytes of
        // {"detail":"unauthorized"}) and the iOS app saved it as
        // the audio file. BackgroundDownloadService now also checks
        // the HTTP status code and surfaces non-2xx as a failure.
        guard let token = KeychainHelper.shared.read(APIService.authTokenKeychainKey) else {
            print("⚠️ appendToken: no session token in keychain (key=\(APIService.authTokenKeychainKey))")
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
        // 2026-08-13: invoked on main (the Combine subscription
        // uses `.receive(on: .main)`). No more stateQueue
        // indirection — the @Published mutations below need to
        // land on main, and `updateProgress` is also a main-only
        // operation. The Combine sink uses `[weak self]`, so the
        // optional chain is at the call site; once we're in this
        // method, `self` is non-nil.
        guard let index = self.activeDownloads.firstIndex(where: { $0.track.videoId == trackId }) else {
            return
        }
        let taskId = self.activeDownloads[index].id
        self.updateProgress(for: taskId, progress: progress)

        // S13: real progress arrived → reset the stalled-watchdog.
        // The stall counter only increments when progress is unchanged
        // across timer ticks; normal progression keeps it at zero.
        self.lastObservedProgress = progress
        self.stalledTickCount = 0
    }

    func handleDownloadComplete(trackId: String, fileURL: URL) {
        // 2026-08-13: invoked on main (see init). No
        // stateQueue.async wrapper — the entry is already on
        // main, and the @Published mutations in
        // handleDownloadSuccess/Failure need to land on main
        // to avoid the data race documented in the init
        // comment.
        guard let index = self.activeDownloads.firstIndex(where: { $0.track.videoId == trackId }) else {
            return
        }
        let taskId = self.activeDownloads[index].id
        let track = self.activeDownloads[index].track

        // S13: a successful download means the watchdog is no longer
        // needed; cancel it so we don't false-positive-stall the next
        // task that re-uses the timer slot.
        self.progressTimer?.invalidate()
        self.progressTimer = nil

        // Save to Core Data + verify on the SAME context. Previous
        // S17-H / LIBRARY-SAVE-SILENT-FAIL split this into
        // saveDownloadToCoreData (which called a fresh
        // backgroundContext) and verifyLibraryEntry (which called
        // ANOTHER fresh backgroundContext). Two new background
        // contexts don't always see each other's writes reliably
        // — verify could return false even when save succeeded,
        // firing the error haptic on a successful download.
        //
        // saveDownloadToCoreDataWithVerify does save + verify on
        // the same context, returns a single Bool. If the save
        // itself throws, it surfaces the error via ErrorHandler
        // and returns false (no silent success). Uses
        // `performAndWait` internally so it blocks the calling
        // thread (main) for the duration of the save. That's
        // fine — main is already async with respect to the
        // URLSession download.
        let savedOk = self.saveDownloadToCoreDataWithVerify(track: track, fileURL: fileURL)

        if savedOk {
            self.handleDownloadSuccess(taskId, path: fileURL.path)
        } else {
            print("❌ Library save failed for \(track.title) — skipping success haptic")
            // Mark the task as failed (so the UI shows a retry button)
            // and surface a real failure to the user.
            self.handleDownloadFailure(taskId, error: "Library save failed")
        }
        self.isDownloading = false
        self.processQueue()
    }

    func handleDownloadError(trackId: String, error: Error) {
        // 2026-08-13: invoked on main (see init). No
        // stateQueue.async wrapper.
        guard let index = self.activeDownloads.firstIndex(where: { $0.track.videoId == trackId }) else {
            return
        }
        let taskId = self.activeDownloads[index].id

        // S13: failed download → stop the watchdog.
        self.progressTimer?.invalidate()
        self.progressTimer = nil

        self.handleDownloadFailure(taskId, error: error.localizedDescription)
        self.isDownloading = false
        self.processQueue()
    }

    /// Save the download to CoreData AND verify it persisted, on a
    /// single context. Returns true only when both the save and the
    /// on-disk file check pass.
    ///
    /// S17-H / LIBRARY-SAVE-SAME-CTX (2026-08-08): the previous
    /// version split this into `saveDownloadToCoreData` +
    /// `verifyLibraryEntry`, each calling
    /// `PersistenceController.shared.backgroundContext` (which
    /// returns a fresh `newBackgroundContext()` on every call).
    /// Two new background contexts don't reliably see each other's
    /// writes — verify could return false even when save succeeded,
    /// firing the error haptic on a successful download. The
    /// 2026-08-08 "haptic on cancel, no Library entry" report was
    /// this exact bug, made worse by the actual /library 401 (the
    /// other fix in this commit) that prevented the file from ever
    /// being downloaded in the first place.
    ///
    /// On any failure path (save throws, fetch returns nothing,
    /// file missing on disk) this surfaces the error via
    /// ErrorHandler so the user gets a toast, not just a silent
    /// haptic.
    private func saveDownloadToCoreDataWithVerify(track: Track, fileURL: URL) -> Bool {
        // Single context for save + verify. Using viewContext for
        // the verify would auto-merge, but writing to viewContext
        // and reading from it on the same call is fragile (the
        // main-thread viewContext isn't a write context). A single
        // background context is the right place for both.
        let context = PersistenceController.shared.backgroundContext

        var success = false

        context.performAndWait {
            do {
                // Fetch existing track or create new one (fetch-or-create pattern)
                let cdTrack: CDTrack
                let trackRequest: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                trackRequest.predicate = NSPredicate(format: "videoId == %@", track.videoId)
                trackRequest.fetchLimit = 1

                if let existingTrack = try context.fetch(trackRequest).first {
                    cdTrack = existingTrack
                    print("📀 Using existing CDTrack: \(track.title)")
                } else {
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
                    existingDownload.localPath = fileURL.path
                    existingDownload.fileSize = Int64((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0)
                    existingDownload.downloadedAt = Date()
                    print("📀 Updated existing CDDownloadedTrack: \(track.title)")
                } else {
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

                // Same-context verify: refetch the row we just
                // wrote and confirm both the row exists and the
                // file is on disk. Done in the same performAndWait
                // so we know the save has flushed and our fetch
                // sees the new row.
                let verifyRequest: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
                verifyRequest.predicate = NSPredicate(format: "track.videoId == %@", track.videoId)
                verifyRequest.fetchLimit = 1

                if let row = try context.fetch(verifyRequest).first,
                   !row.localPath.isEmpty,
                   FileManager.default.fileExists(atPath: row.localPath) {
                    success = true
                } else {
                    let pathCheck = (try? context.fetch(verifyRequest).first?.localPath) ?? "<no row>"
                    print("❌ verify-after-save: row missing or file gone (path=\(pathCheck))")
                    DispatchQueue.main.async {
                        ErrorHandler.shared.show(
                            .downloadFailed("Saved \(track.title) but couldn't find it again — try re-downloading")
                        )
                    }
                }
            } catch {
                let errorDesc = "\(error)"
                print("❌ Failed to save download to Core Data: \(errorDesc)")
                print("   track.videoId = \(track.videoId), fileURL = \(fileURL.path)")
                context.rollback()
                DispatchQueue.main.async {
                    ErrorHandler.shared.show(
                        .downloadFailed("Couldn't save \(track.title) to library: \(errorDesc)")
                    )
                }
            }
        }

        return success
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
                let task = self.activeDownloads[index]
                let title = task.track.title
                let localizedError = error
                var failedTask = task
                failedTask.status = .failed(localizedError)
                failedTask.completionTime = Date()

                self.activeDownloads.remove(at: index)
                self.completedDownloads.append(failedTask)

                HapticManager.error()

                // S17-H / DOWNLOAD-FAILURE-TOAST (2026-08-08):
                // also surface a toast. Previously the only user
                // signal for a download failure was the error
                // haptic — no ErrorHandler call, so the user
                // saw the ring disappear + haptic and had no
                // idea what went wrong. The 2026-08-08 report
                // "haptic on cancel, no error, nothing in
                // library" was the most recent symptom: a
                // background 401 meant the file never landed,
                // the error haptic fired silently, and the
                // Library stayed empty. Now every failure path
                // shows a toast.
                //
                // Skip the toast for "stalled" messages where
                // the stall watchdog already shows a toast (in
                // stallWatchdogTick). Otherwise we'd toast
                // twice.
                if !localizedError.lowercased().contains("stalled") {
                    ErrorHandler.shared.show(
                        .downloadFailed("\(title): \(localizedError)")
                    )
                }
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
