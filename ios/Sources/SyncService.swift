import Foundation
import Combine

struct SyncSessionContext: Equatable {
    var owner: SyncOwner
    var backend: BackendIdentity
    var generation: UInt64
    var token: String
}

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    enum SyncState {
        case idle, uploading, downloading, merging
        case completed(at: Date)
        case failed(message: String)
    }
    @Published private(set) var state: SyncState = .idle
    @Published private(set) var savedLibraries: [SavedSyncLibrary] = []
    @Published private(set) var lastSuccess: Date?
    private var currentTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var store: SyncLocalStore?
    private let session: URLSession
    private let sessionContext: () -> SyncSessionContext?

    init(session: URLSession = .shared, store: SyncLocalStore? = nil,
         context: (() -> SyncSessionContext?)? = nil) {
        self.session = session
        self.store = store
        self.sessionContext = context ?? {
            let auth = AuthService.shared
            let backend = BackendConfiguration.shared.identity
            guard auth.isAuthenticated, let user = auth.userId,
                  let token = APIService.sessionToken(for: backend.origin) else { return nil }
            return SyncSessionContext(owner: SyncOwner(origin: backend.origin.absoluteString, userId: user),
                backend: backend, generation: auth.sessionGeneration, token: token)
        }
    }

    var isBusy: Bool {
        switch state { case .uploading, .downloading, .merging: return true; default: return false }
    }

    var statusText: String {
        switch state {
        case .idle: return "Backup is ready when you sign in."
        case .uploading: return "Saving backup on your Mac…"
        case .downloading: return "Checking your Mac’s backup…"
        case .merging: return "Restoring your library…"
        case .completed: return "Your library is backed up on your Mac."
        case .failed(let message): return message
        }
    }

    func handleSignIn(isNewUser: Bool) { retry() }
    func handleSessionRestored() { retry() }

    func handleSignOut() {
        generation &+= 1
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    func retry() {
        handleSignOut()
        let operation = generation
        currentTask = Task { [weak self] in await self?.run(operation: operation) }
    }

    func importSavedLibrary(id: String) {
        guard !isBusy, let owner = currentOwner(), let store else { return }
        do {
            try store.importArchive(id: id, owner: owner)
            retry()
        } catch { state = .failed(message: error.localizedDescription) }
    }

    private func currentOwner() -> SyncOwner? {
        sessionContext()?.owner
    }

    /// Awaitable seam for isolated transport tests and explicit foreground backup actions.
    func syncNow() async {
        handleSignOut()
        await run(operation: generation)
    }

    private func run(operation: UInt64) async {
        guard let context = sessionContext() else { return }
        let owner = context.owner, identity = context.backend, token = context.token
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard operation == generation, sessionContext() == context else {
                throw CancellationError()
            }
        }
        do {
            if store == nil { store = try SyncLocalStore.live() }
            guard let store else { throw SyncValidationError.invalidSnapshot }
            savedLibraries = store.control.archives
            lastSuccess = store.control.lastSuccess
            for attempt in 0..<3 {
                try checkCurrent()
                state = .downloading
                let remote = try await fetch(identity: identity, token: token)
                try checkCurrent()
                _ = try store.prepare(owner: owner)
                let local = try store.capture()
                let merged = try SyncMerge.merge(base: store.control.baselines[owner.key], local: local, remote: remote.snapshot)
                state = .merging
                try store.apply(merged, owner: owner)
                try checkCurrent()
                state = .uploading
                do {
                    let uploaded = try await upload(merged, baseRevision: remote.revision, identity: identity, token: token)
                    try checkCurrent()
                    guard uploaded.snapshot == merged else { throw SyncValidationError.invalidSnapshot }
                    try store.markSynced(merged, owner: owner)
                    lastSuccess = store.control.lastSuccess
                    savedLibraries = store.control.archives
                    state = .completed(at: lastSuccess ?? Date())
                    return
                } catch SyncNetworkError.conflict where attempt < 2 { continue }
            }
            throw SyncNetworkError.conflict
        } catch is CancellationError {
            // A new owner/host/task owns status now; discard this operation completely.
        } catch {
            guard operation == generation else { return }
            state = .failed(message: error.localizedDescription)
            if let store { savedLibraries = store.control.archives }
        }
    }

    private func fetch(identity: BackendIdentity, token: String) async throws -> SyncEnvelope {
        var request = URLRequest(url: identity.url(path: "/sync/v2"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func upload(_ snapshot: SyncSnapshot, baseRevision: Int, identity: BackendIdentity, token: String) async throws -> SyncEnvelope {
        var request = URLRequest(url: identity.url(path: "/sync/v2"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SyncUpload(baseRevision: baseRevision,
            operationId: UUID().uuidString, snapshot: snapshot))
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> SyncEnvelope {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncNetworkError.unavailable }
        switch http.statusCode {
        case 200: return try JSONDecoder().decode(SyncEnvelope.self, from: data).validated()
        case 401: throw SyncNetworkError.authentication
        case 409: throw SyncNetworkError.conflict
        case 404, 426: throw SyncValidationError.unsupportedVersion
        default: throw SyncNetworkError.unavailable
        }
    }
}

enum SyncNetworkError: LocalizedError {
    case authentication, conflict, unavailable
    var errorDescription: String? {
        switch self {
        case .authentication: return "Sign in again to resume backup. Your local library is preserved."
        case .conflict: return "The backup changed on another device. Your library is preserved; retry when that device has finished."
        case .unavailable: return "Could not reach a usable backup on your Mac. Your library is preserved. Try again later."
        }
    }
}
