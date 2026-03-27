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
    case decodingError(Error)
    case networkError(Error)
}

class APIService {
    static let shared = APIService()
    
    // ⚠️ ⚠️ ⚠️ CHANGE THIS TO YOUR MAC'S IP ADDRESS ⚠️ ⚠️ ⚠️
    // Find your IP: run 'make ip' in terminal
    // Example: "http://192.x.x.x:8181"
    let baseURL: String = {
        #if targetEnvironment(simulator)
        return "http://localhost:8181"
        #else
        // Set this to your Mac's Tailscale hostname or local IP
        // Example: "http://192.168.x.x:8181" or "http://your-machine-name:8181"
        return "http://100.77.213.42:8181"
        #endif
    }()
    
    private let session = URLSession.shared
    
    private init() {
        print("🔗 APIService initialized with baseURL: \(baseURL)")
    }
    
    func search(query: String, limit: Int = 20) -> AnyPublisher<[Track], APIError> {
        guard let url = URL(string: "\(baseURL)/search") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["query": query, "limit": limit]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        return session.dataTaskPublisher(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<Data, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                if httpResponse.statusCode != 200 {
                    print("❌ HTTP \(httpResponse.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "")).eraseToAnyPublisher()
                }
                return Just(data).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .decode(type: [Track].self, decoder: JSONDecoder())
            .mapError { APIError.decodingError($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // MARK: - Charts / Trending

    func fetchTrending() -> AnyPublisher<[Track], APIError> {
        guard let url = URL(string: "\(baseURL)/charts") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        return session.dataTaskPublisher(for: url)
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

        return session.dataTaskPublisher(for: url)
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
        // Use proxy-stream endpoint with format preference
        // preferM4A=true will prioritize m4a (AAC) format which works better on iOS
        // quality="low" for fast start (70kbps), "high" for best quality (160kbps)
        let ext = preferM4A ? "m4a" : "webm"
        guard var urlComponents = URLComponents(string: "\(baseURL)/proxy-stream/\(videoId).\(ext)") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        // Add quality query parameter
        urlComponents.queryItems = [URLQueryItem(name: "quality", value: quality)]

        guard let url = urlComponents.url else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        // Validate URL with a HEAD request before returning
        // This ensures the backend is reachable and the stream URL is valid
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10

        return session.dataTaskPublisher(for: request)
            .mapError { APIError.networkError($0) }
            .flatMap { data, response -> AnyPublisher<StreamInfo, APIError> in
                guard let httpResponse = response as? HTTPURLResponse else {
                    return Fail(error: APIError.invalidResponse).eraseToAnyPublisher()
                }
                guard httpResponse.statusCode == 200 else {
                    return Fail(error: APIError.httpError(statusCode: httpResponse.statusCode, message: "Stream not available")).eraseToAnyPublisher()
                }

                // Return stream info with appropriate MIME type
                let mimeType = preferM4A ? "audio/mp4" : "audio/webm"
                let bitrate = quality == "low" ? 70000 : 160000
                let streamInfo = StreamInfo(
                    streamUrl: url.absoluteString,
                    mimeType: mimeType,
                    bitrate: bitrate
                )
                return Just(streamInfo).setFailureType(to: APIError.self).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func downloadTrack(_ track: Track) -> AnyPublisher<String, APIError> {
        guard let url = URL(string: "\(baseURL)/download") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        
        return session.dataTaskPublisher(for: request)
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
            .map { $0.filePath }
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
        
        return session.dataTaskPublisher(for: url)
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
        
        return session.dataTaskPublisher(for: request)
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
        
        return session.dataTaskPublisher(for: url)
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
    
    // MARK: - Playlist Search
    
    func searchPlaylists(query: String, limit: Int = 10) -> AnyPublisher<[YouTubePlaylist], APIError> {
        guard let url = URL(string: "\(baseURL)/search/playlists") else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["query": query, "limit": limit]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        return session.dataTaskPublisher(for: request)
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
        
        return session.dataTaskPublisher(for: url)
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
        
        return session.dataTaskPublisher(for: url)
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

        return URLSession.shared.dataTaskPublisher(for: url)
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

// MARK: - Waveform Response Model

private struct WaveformResponse: Decodable {
    let peaks: [Float]
}
