//
//  WaveformService.swift
//  YTAudioPlayer
//
//  Fetches, caches, and generates fallback waveform peak data for tracks.
//  Two-tier cache: in-memory + disk (AppSupport/waveforms/).
//  Falls back to a deterministic pseudo-waveform for streaming tracks.
//

import Foundation
import Combine

final class WaveformService: ObservableObject {
    static let shared = WaveformService()

    // MARK: - Cache

    private var memoryCache: [String: [Float]] = [:]
    private let cacheDir: URL
    private let cacheLock = NSLock()

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Async fetch: memory cache → disk cache → backend → pseudo fallback.
    func waveform(for videoId: String) async -> [Float] {
        // 1. Memory cache
        cacheLock.lock()
        if let cached = memoryCache[videoId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // 2. Disk cache
        if let diskPeaks = loadFromDisk(videoId: videoId) {
            cacheLock.lock()
            memoryCache[videoId] = diskPeaks
            cacheLock.unlock()
            return diskPeaks
        }

        // 3. Fetch from backend
        if let remotePeaks = await fetchFromBackend(videoId: videoId) {
            saveToDisk(videoId: videoId, peaks: remotePeaks)
            cacheLock.lock()
            memoryCache[videoId] = remotePeaks
            cacheLock.unlock()
            return remotePeaks
        }

        // 4. Pseudo-waveform fallback (deterministic per videoId)
        let fallback = pseudoWaveform(for: videoId)
        cacheLock.lock()
        memoryCache[videoId] = fallback
        cacheLock.unlock()
        return fallback
    }

    /// Pre-warm cache for a downloaded track (fire-and-forget).
    func prefetch(videoId: String) {
        Task { _ = await waveform(for: videoId) }
    }

    // MARK: - Backend Fetch

    private func fetchFromBackend(videoId: String) async -> [Float]? {
        return try? await withCheckedThrowingContinuation { continuation in
            APIService.shared.fetchWaveform(videoId: videoId)
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let err) = completion {
                            continuation.resume(throwing: err)
                        }
                    },
                    receiveValue: { peaks in
                        continuation.resume(returning: peaks)
                    }
                )
                .store(in: &self.cancellables)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Disk Cache

    private func diskURL(videoId: String) -> URL {
        cacheDir.appendingPathComponent("\(videoId).bin")
    }

    private func loadFromDisk(videoId: String) -> [Float]? {
        let url = diskURL(videoId: videoId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self).prefix(count))
        }
    }

    private func saveToDisk(videoId: String, peaks: [Float]) {
        let url = diskURL(videoId: videoId)
        let data = peaks.withUnsafeBytes { Data($0) }
        try? data.write(to: url)
    }

    // MARK: - Pseudo-Waveform (deterministic, seeded by videoId)

    /// Generates a smooth, music-like waveform seeded deterministically from the videoId.
    /// Guaranteed to be the same across app launches for the same videoId.
    func pseudoWaveform(for videoId: String, count: Int = 200) -> [Float] {
        // Seed LCG from videoId bytes
        let seed = videoId.utf8.reduce(UInt64(0)) { acc, byte in
            acc &* 6364136223846793005 &+ UInt64(byte) &+ 1442695040888963407
        }
        var rng = LCGRandom(seed: seed)

        // Generate raw noise
        var raw = (0..<count).map { _ in Float(rng.next()) }

        // Apply multiple smoothing passes for music-like shape
        raw = smoothPass(raw, window: 5)
        raw = smoothPass(raw, window: 9)

        // Boost midrange to look more like a real song waveform
        for i in 0..<count {
            let position = Float(i) / Float(count)
            // Songs tend to have louder middles (chorus)
            let shapeCurve = sin(position * .pi) * 0.3 + 0.7
            raw[i] = min(1.0, raw[i] * shapeCurve)
        }

        // Normalize
        let maxVal = raw.max() ?? 1
        if maxVal > 0 {
            raw = raw.map { $0 / maxVal }
        }

        // Ensure minimum amplitude so waveform is always visible
        return raw.map { max(0.08, $0) }
    }

    private func smoothPass(_ values: [Float], window: Int) -> [Float] {
        let half = window / 2
        return values.enumerated().map { i, _ in
            let start = max(0, i - half)
            let end = min(values.count - 1, i + half)
            let slice = values[start...end]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }
}

// MARK: - Simple LCG Random Number Generator

private struct LCGRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0x7FFFFFFF) / Double(0x7FFFFFFF)
    }
}
