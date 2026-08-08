//
//  APIService.swift
//  YTAudioPlayer
//
//  HTTP client for backend communication
//

import Foundation
import Combine

enum APIError: Error {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    /// S15: 429 with the Retry-After header (in seconds, or nil
    /// if the server didn't send one). The UI uses this to show
    /// a meaningful "Rate limited — try again in Ns" message
    /// instead of the generic "check your internet" the old
    /// `toAppError()` path produced.
    case rateLimited(retryAfter: TimeInterval?)
    case decodingError(Error)
    case networkError(Error)
}

class APIService {
    static let shared = APIService()

    // S15: the previous code hardcoded the Mac's Tailscale IP
    // (`100.77.213.42`) as the device-build default, so the app
    // was non-functional on any other network. Now we read an
    // optional UserDefaults override (`peaceplayer.api_base_url`,
    // settable from the Settings screen or by writing
    // `defaults write com.ytaudioplayer.app peaceplayer.api_base_url http://...`
    // from a shell). Falls back to the simulator-friendly
    // localhost and the Tailscale defaults for compatibility.
    static let baseURLOverrideDefaultsKey = "peaceplayer.api_base_url"

    // S17 (CV-4): now a COMPUTED property that re-reads
    // UserDefaults on every access. The previous `let`
    // cached the value at APIService.shared init, so a Settings
    // change didn't take effect until the next app launch. With
    // this, tapping "Save" in the backend-host row is enough —
    // no restart, and the "Test connection" button below the
    // text field sees the new URL on the same frame.
    var baseURL: String {
        if let override = UserDefaults.standard.string(forKey: APIService.baseURLOverrideDefaultsKey),
           !override.isEmpty {
            return override
        }
        #if targetEnvironment(simulator)
        return "http://localhost:8181"
        #else
        // Default for device builds: Tailscale IP. Override
        // with the UserDefaults key above if your Mac is on a
        // different network.
        return "http://100.77.213.42:8181"
        #endif
    }

    // S17 (CV-3): the auth token is stored in Keychain by
    // AuthService under the same key both sides agree on. We
    // read it lazily on every request so a fresh sign-in is
    // picked up without restarting APIService.
    //
    // S17-H follow-up: `static let` (internal) instead of
    // `private static let` so StreamURLCache can read the same
    // key when building its cache key (it folds baseURL + token
    // hash + videoId so a sign-out / sign-in / Backend Host
    // change auto-invalidates the cache). Keeping the key as the
    // single source of truth in APIService avoids string drift
    // between callers.
    static let authTokenKeychainKey = "peaceplayer.session_token"
    private let keychain = KeychainHelper.shared
    private var currentAuthToken: String? {
        keychain.read(APIService.authTokenKeychainKey)
    }

    private let session: URLSession
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 0.5

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        print("🔗 APIService initialized with baseURL: \(baseURL)")
    }

    // MARK: - Request helper

    /// S17-H (failure modes 6): the previous `maxRetries` and
    /// `retryDelay` constants were declared but never wired. Every
    /// transient network blip (5s in a tunnel, brief Wi-Fi drop)
    /// surfaced to the user as an error toast. Now every request
    /// retries with short exponential backoff before giving up.
    ///
    /// The retry only catches URLErrors (transport-level), not
    /// HTTP 4xx / 5xx — those are semantic errors from the server
    /// and shouldn't be retried. Built with `.catch` + `.delay`
    /// because Combine's `.retry(_:)` has no backoff.
    ///
    /// S17-H follow-up (2026-07-26): the recursive call now carries
    /// the current `attempt` through, instead of always starting at
    /// 1. The previous code called `self.dataTaskWithRetry(for:)`
    /// from inside `retryPublisher`, but that helper has its own
    /// `.catch` that calls `retryPublisher(attempt: 1)` — the inner
    /// catch fires BEFORE the outer catch, so the attempt counter
    /// never incremented and the `attempt >= maxRetries` check at
    /// line 112 never triggered. If the network was failing, the
    /// retry would recurse forever with a 0.5s delay on each
    /// iteration; the search would hang in the skeleton view with
    /// no error. Fix: thread the `attempt` through every call.
    private func dataTaskWithRetry(
        for request: URLRequest,
        attempt: Int = 1
    ) -> AnyPublisher<(data: Data, response: URLResponse), URLError> {
        return session.dataTaskPublisher(for: request)
            .catch { [weak self] error -> AnyPublisher<(data: Data, response: URLResponse), URLError> in
                guard let self = self else {
                    return Fail(error: error).eraseToAnyPublisher()
                }
                return self.retryPublisher(for: request, attempt: attempt + 1, originalError: error)
            }
            .eraseToAnyPublisher()
    }

    private func retryPublisher(
        for request: URLRequest,
        attempt: Int,
        originalError: URLError
    ) -> AnyPublisher<(data: Data, response: URLResponse), URLError> {
        if attempt > maxRetries {
            return Fail(error: originalError).eraseToAnyPublisher()
        }
        let delay = retryDelay * pow(2.0, Double(attempt - 1))
        return Just(())
            .delay(for: .seconds(delay), scheduler: DispatchQueue.global())
            .setFailureType(to: URLError.self)
            .flatMap { [weak self] _ -> AnyPublisher<(data: Data, response: URLResponse), URLError> in
                guard let self = self else {
                    return Fail(error: originalError).eraseToAnyPublisher()
                }
                // Pass the current `attempt` through to the next
                // request so the counter actually increments. The
                // previous version called `self.dataTaskWithRetry`
                // (no attempt arg), which reset to 1 and shadowed
                // the outer `attempt + 1` in its own catch.
                return self.dataTaskWithRetry(for: request, attempt: attempt)
            }
            .eraseToAnyPublisher()
    }

    // S17 (CV-3): attach the session JWT as a Bearer token on
    // every request, if a session exists. Unauthenticated
    // endpoints (sign-in, health) ignore the header; the
    // backend now enforces auth on the rest, so callers that
    // haven't signed in yet will see a 401 — and ErrorHandler
    // already shows "Session expired — sign in again" for that
    // case. This is what makes the header the source of truth
    // instead of the previous ad-hoc SyncService/AuthService
    // inline headers.
    static func addAuthHeader(to request: inout URLRequest) {
        if let token = KeychainHelper.shared.read(APIService.authTokenKeychainKey),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func addAuthHeader(to request: inout URLRequest) {
        APIService.addAuthHeader(to: &request)
    }

    func search(query: String, limit: Int = 20) -> AnyPublisher<[Track], APIError> {
        // S17-H diagnostic: log the URL + baseURL being used so we
        // can spot a stale Tailscale IP override (the previous fix
        // for "couldn't process data" added the response body log
        // inside the 200 branch; the URL here is the request-side
        // counterpart).
        let baseURLString = APIService.shared.baseURL
        print("🔍 [APIService] search starting — baseURL=\(baseURLString) query=\(query) limit=\(limit)")

        guard let url = URL(string: "\(baseURL)/search") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeader(to: &request)

        let body: [String: Any] = ["query": query, "limit": limit]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("❌ [APIService] HTTP \(httpResponse.statusCode): \(body.prefix(500))")
                    // S15: surface 429 separately so the UI can show a
                    // real "rate limited" message + Retry-After. The
                    // previous code path collapsed 429 into
                    // `.httpError` and the ErrorHandler then turned
                    // it into a generic "check your internet".
                    if httpResponse.statusCode == 429 {
                        let retryAfter: TimeInterval? = {
                            if let raw = httpResponse.value(forHTTPHeaderField: "Retry-After") {
                                return TimeInterval(raw)
                            }
                            return nil
                        }()
                        return Fail(error: APIError.rateLimited(retryAfter: retryAfter))
                            .eraseToAnyPublisher()
                    }
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: body)).eraseToAnyPublisher()
                }
                // S17-H diagnostic: log the response body when a
                // successful 200 still fails to decode. The user
                // reported "couldn't process data" (the .parsing
                // error) which means we got a 200 but the JSON
                // didn't match [Track]. Logging the body + URL lets
                // us see whether the response is an empty array, a
                // single object, HTML, or something else entirely
                // (e.g., a proxy interception page from a stale
                // Tailscale IP).
                if let preview = String(data: data.prefix(500), encoding: .utf8) {
                    print("🔍 [APIService] search 200 body (\(data.count) bytes): \(preview)")
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [Track].self, decoder: JSONDecoder())
            .mapError { error -> APIError in
                print("❌ [APIService] Search decode error: \(error)")
                return APIError.decodingError(error)
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // MARK: - Charts / Trending

    func fetchTrending() -> AnyPublisher<[Track], APIError> {
        guard let url = URL(string: "\(baseURL)/charts") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: ChartsResponse.self, decoder: JSONDecoder())
            .map { $0.tracks }
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func fetchNewReleases() -> AnyPublisher<[Track], APIError> {
        guard let url = URL(string: "\(baseURL)/new-releases") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: NewReleasesResponse.self, decoder: JSONDecoder())
            .map { $0.tracks }
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func getStreamUrl(videoId: String, preferM4A: Bool = true, quality: String = "low") -> AnyPublisher<StreamInfo, APIError> {
        // S17-H (2026-07-27 00:49): /stream now returns JSON
        // with the iOS app's Bearer token embedded in the
        // query string of the audio URL. The iOS app hands
        // that URL to AVPlayer, which fetches the URL and
        // /audio authenticates via the ?token= fallback.
        // (The previous round redirected to /audio, but
        // URLSession stripped the Authorization header on
        // the redirect, so /audio returned 401.)
        //
        // /audio downloads the YouTube webm/Opus body,
        // transcodes to AAC/M4A via ffmpeg, caches the
        // result on disk, and serves with Range support.
        // iOS plays AAC universally — the previous
        // NSOSStatusErrorDomain -12847 (kAudioConverterErr_
        // FormatNotSupported) was because iOS's hardware
        // decoder can't handle YouTube's specific Opus
        // profile.
        guard let url = URL(string: "\(baseURL)/stream/\(videoId)") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        // S17-H follow-up: bumped from 8s to 30s. Cold yt-dlp
        // extractions (the HLS transcode pipeline at
        // server.py:2942) can take 10-30s for tracks that need
        // the n-challenge + remote_components solver. The old
        // 8s timeout was racing with the backend and surfacing
        // "Couldn't play this track" for fresh Echoes-class
        // tracks before the HLS pipeline ever had a chance to
        // start streaming. 30s gives the cold path headroom;
        // a genuine backend hang will still surface as a
        // timeout, just a few seconds later.
        request.timeoutInterval = 30
        addAuthHeader(to: &request)

        return dataTaskWithRetry(for: request)
            .mapError { error -> APIError in
                if let apiError = error as? APIError { return apiError }
                return APIError.networkError(error)
            }
            .flatMap { data, response -> AnyPublisher<StreamInfo, APIError> in
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let bodyStr = String(data: data, encoding: .utf8) ?? ""
                    print("getStreamUrl error " + videoId + " HTTP " + String(status))
                    return Fail(error: APIError.httpError(statusCode: status, message: bodyStr)).eraseToAnyPublisher()
                }
                do {
                    let info = try JSONDecoder().decode(StreamInfo.self, from: data)
                    let resolved = self.resolveStreamURL(info.streamUrl)
                    print("getStreamUrl " + videoId + " -> " + String(resolved.prefix(120)))
                    return Just(StreamInfo(
                        streamUrl: resolved,
                        mimeType: info.mimeType,
                        bitrate: info.bitrate
                    )).setFailureType(to: APIError.self).eraseToAnyPublisher()
                } catch {
                    return Fail(error: APIError.decodingError(error)).eraseToAnyPublisher()
                }
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// S17-H: resolve a path-only or path-with-query stream URL
    /// returned by /stream against the current baseURL. /stream
    /// returns e.g. "/audio/VIDEOID.m4a?token=..." which needs
    /// the baseURL scheme + host prepended for AVPlayer.
    private func resolveStreamURL(_ streamUrl: String) -> String {
        if let abs = URL(string: streamUrl), abs.scheme != nil {
            return abs.absoluteString
        }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + streamUrl
    }

    func downloadTrack(_ track: Track) -> AnyPublisher<DownloadResponse, APIError> {
        guard let url = URL(string: "\(baseURL)/download") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeader(to: &request)
        // S17-H / DOWNLOAD-CDN-FIX (2026-08-08): server-side
        // YouTube fetch + ffmpeg convert can take 5-10s on a
        // cold track. 120s leaves headroom for a busy CPU or a
        // long first-call yt-dlp n-challenge.
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "videoId": track.videoId,
            "title": track.title,
            "artists": track.artists,
            "album": track.album
        ]
        // Add thumbnail as string (not URL) to avoid JSON serialization crash
        if let thumbnail = track.thumbnails.first?.url.absoluteString {
            body["thumbnail"] = thumbnail
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("❌ Download HTTP \(httpResponse.statusCode): \(body)")
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: body)).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: DownloadResponse.self, decoder: JSONDecoder())
            .mapError { error -> APIError in
                if let apiError = error as? APIError {
                    return apiError
                }
                return APIError.decodingError(error)
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func fetchLibrary() -> AnyPublisher<[LocalTrack], APIError> {
        guard let url = URL(string: "\(baseURL)/library") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .map { $0.data }
            .decode(type: LibraryResponse.self, decoder: JSONDecoder())
            .map { $0.tracks }
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func localFileURL(for track: LocalTrack) -> URL? {
        URL(string: "\(baseURL)/local-play/\(track.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")")
    }
    
    func deleteLibraryFile(_ track: LocalTrack) -> AnyPublisher<Void, APIError> {
        guard let url = URL(string: "\(baseURL)/library/\(track.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuthHeader(to: &request)

        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                    return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
                } else {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
            }
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getLyrics(videoId: String) -> AnyPublisher<[LyricsLine], APIError> {
        guard let url = URL(string: "\(baseURL)/lyrics/\(videoId)") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode == 404 {
                    // Lyrics not available - return empty rather than error
                    print("🎵 Lyrics not available for \(videoId)")
                    return Fail(error: APIError.httpError(statusCode: 404, message: "Lyrics not available")).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("❌ Lyrics HTTP \(httpResponse.statusCode): \(body)")
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: body)).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: LyricsResponse.self, decoder: JSONDecoder())
            .map { response -> [LyricsLine] in
                print("🎵 Got lyrics: \(response.lyrics.prefix(100))...")
                return self.parseLyrics(response.lyrics)
            }
            .mapError { error -> APIError in
                if let apiError = error as? APIError {
                    return apiError
                }
                return APIError.decodingError(error)
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // MARK: - Guitar Chords

    func getChords(title: String, artist: String) -> AnyPublisher<ChordsResult, APIError> {
        var components = URLComponents(string: "\(baseURL)/chords")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist)
        ]
        guard let url = components?.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let http = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if http.statusCode == 404 {
                    return Fail(error: APIError.httpError(statusCode: 404, message: "No chords found")).eraseToAnyPublisher()
                }
                guard http.statusCode == 200 else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    return Fail(error: APIError.httpError(statusCode: http.statusCode, message: body)).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: ChordsResult.self, decoder: JSONDecoder())
            .mapError { error -> APIError in
                if let apiError = error as? APIError { return apiError }
                return APIError.decodingError(error)
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // MARK: - Playlist Search
    
    func searchPlaylists(query: String, limit: Int = 10) -> AnyPublisher<[YouTubePlaylist], APIError> {
        guard let url = URL(string: "\(baseURL)/search/playlists") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeader(to: &request)

        let body: [String: Any] = ["query": query, "limit": limit]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [YouTubePlaylist].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getPlaylistDetails(playlistId: String, limit: Int = 100) -> AnyPublisher<YouTubePlaylistDetails, APIError> {
        guard let url = URL(string: "\(baseURL)/playlist/\(playlistId)?limit=\(limit)") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: YouTubePlaylistDetails.self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getRadio(for videoId: String) -> AnyPublisher<[Track], APIError> {
        guard let url = URL(string: "\(baseURL)/radio/\(videoId)") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [Track].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // MARK: - Radio Stations
    
    func searchRadioStations(query: String, limit: Int = 20) -> AnyPublisher<[RadioStation], APIError> {
        guard var components = URLComponents(string: "\(baseURL)/radio-stations/search") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [RadioStation].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getRadioStationsByGenre(tag: String, limit: Int = 30) -> AnyPublisher<[RadioStation], APIError> {
        guard var components = URLComponents(string: "\(baseURL)/radio-stations/genre/\(tag)") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [RadioStation].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getTopRadioStations(limit: Int = 30) -> AnyPublisher<[RadioStation], APIError> {
        guard var components = URLComponents(string: "\(baseURL)/radio-stations/top") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [RadioStation].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func registerRadioClick(stationuuid: String) -> AnyPublisher<Void, APIError> {
        guard let url = URL(string: "\(baseURL)/radio-stations/\(stationuuid)/click") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuthHeader(to: &request)

        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Void, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(()).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // MARK: - Podcasts
    
    func searchPodcasts(query: String, limit: Int = 20) -> AnyPublisher<[PodcastShow], APIError> {
        guard var components = URLComponents(string: "\(baseURL)/podcasts/search") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [PodcastShow].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getPodcastEpisodes(feedUrl: String, limit: Int = 50) -> AnyPublisher<[PodcastEpisode], APIError> {
        guard var components = URLComponents(string: "\(baseURL)/podcasts/episodes") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        components.queryItems = [
            URLQueryItem(name: "feedUrl", value: feedUrl),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [PodcastEpisode].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getTopPodcasts(genre: String = "", limit: Int = 20) -> AnyPublisher<[PodcastShow], APIError> {
        guard var components = URLComponents(string: "\(baseURL)/podcasts/top") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if !genre.isEmpty {
            queryItems.append(URLQueryItem(name: "genre", value: genre))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [PodcastShow].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // MARK: - Audiobooks
    
    func searchAudiobooks(query: String, limit: Int = 20) -> AnyPublisher<[Audiobook], APIError> {
        guard var components = URLComponents(string: "\(baseURL)/audiobooks/search") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [Audiobook].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getTopAudiobooks(limit: Int = 20, offset: Int = 0) -> AnyPublisher<[Audiobook], APIError> {
        guard var components = URLComponents(string: "\(baseURL)/audiobooks/top") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [Audiobook].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getAudiobooksByGenre(genre: String, limit: Int = 20) -> AnyPublisher<[Audiobook], APIError> {
        let encodedGenre = genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? genre
        guard var components = URLComponents(string: "\(baseURL)/audiobooks/genre/\(encodedGenre)") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [Audiobook].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func getAudiobookChapters(bookId: String, rssUrl: String? = nil) -> AnyPublisher<AudiobookChaptersResponse, APIError> {
        guard var components = URLComponents(string: "\(baseURL)/audiobooks/\(bookId)/chapters") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        var queryItems: [URLQueryItem] = []
        if let rssUrl = rssUrl, !rssUrl.isEmpty {
            queryItems.append(URLQueryItem(name: "rssUrl", value: rssUrl))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return dataTaskWithRetry(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: AudiobookChaptersResponse.self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // MARK: - Lyrics Parsing
    
    private func parseLyrics(_ lyricsText: String) -> [LyricsLine] {
        // Check if it's LRC format (e.g., "[00:12.34] Lyrics text")
        let lines = lyricsText.components(separatedBy: .newlines)
        var parsedLines: [LyricsLine] = []
        
        let lrcPattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)"#
        let regex = try? NSRegularExpression(pattern: lrcPattern, options: [])
        
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex?.firstMatch(in: line, options: [], range: range) {
                let minRange = Range(match.range(at: 1), in: line)!
                let secRange = Range(match.range(at: 2), in: line)!
                let msRange = Range(match.range(at: 3), in: line)!
                let textRange = Range(match.range(at: 4), in: line)!
                
                let minutes = Double(line[minRange]) ?? 0
                let seconds = Double(line[secRange]) ?? 0
                let milliseconds = Double(line[msRange]) ?? 0
                let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
                
                let time = minutes * 60 + seconds + milliseconds / 1000
                
                if !text.isEmpty {
                    parsedLines.append(LyricsLine(time: time, text: text))
                }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Plain text line without timestamp - append to previous or add as untimed
                if let last = parsedLines.last {
                    parsedLines.append(LyricsLine(time: last.time + 5, text: line.trimmingCharacters(in: .whitespaces)))
                } else {
                    parsedLines.append(LyricsLine(time: 0, text: line.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        
        // Sort by time
        parsedLines.sort { $0.time < $1.time }
        
        // If no timestamps parsed, distribute evenly
        if parsedLines.count > 1 && parsedLines.allSatisfy({ $0.time == 0 }) {
            let duration = 180.0 // Assume 3 min song
            let interval = duration / Double(parsedLines.count)
            parsedLines = parsedLines.enumerated().map { index, line in
                LyricsLine(time: Double(index) * interval, text: line.text)
            }
        }
        
        return parsedLines.isEmpty ? [LyricsLine(time: 0, text: "No lyrics available")] : parsedLines
    }

    // MARK: - Waveform

    /// Fetch pre-computed waveform peaks for a video ID from the backend.
    /// Returns a list of 200 normalized Float values (0.0–1.0).
    func fetchWaveform(videoId: String) -> AnyPublisher<[Float], APIError> {
        guard let url = URL(string: "\(baseURL)/waveform/\(videoId)") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response in
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw APIError.networkError(URLError(.badServerResponse))
                }
                return data
            }
            .decode(type: WaveformResponse.self, decoder: JSONDecoder())
            .map(\.peaks)
            .mapError { error -> APIError in
                if let apiError = error as? APIError { return apiError }
                return APIError.networkError(error)
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - Audiobook Response Model

struct AudiobookChaptersResponse: Codable {
    let coverUrl: String
    let chapters: [AudiobookChapter]
}

// MARK: - Chords Response Model

struct ChordsResult: Codable {
    let found: Bool
    let title: String
    let artist: String
    let url: String
    let songsterrId: Int
    let hasChords: Bool
    let hasPlayer: Bool
}

// MARK: - Waveform Response Model

private struct WaveformResponse: Decodable {
    let peaks: [Float]
}
