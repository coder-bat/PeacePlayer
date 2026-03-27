//
//  AudioVisualizerEngine.swift
//  YTAudioPlayer
//
//  Real-time FFT audio visualizer engine using MTAudioProcessingTap + Accelerate vDSP.
//  Intercepts PCM samples from AVPlayerItem and publishes 32 frequency band magnitudes.
//

import Foundation
import AVFoundation
import Accelerate
import Combine
import MediaToolbox
import SwiftUI

final class AudioVisualizerEngine: ObservableObject {
    static let shared = AudioVisualizerEngine()

    // MARK: - Published State

    /// 32 normalized frequency band magnitudes (0.0 to 1.0), updated at ~30fps
    @Published var bands: [Float] = Array(repeating: 0, count: 32)

    /// Whether the tap is currently active
    @Published var isActive: Bool = false

    // MARK: - Constants

    private let bandCount = 32
    private let fftSize = 4096
    private let sampleRate: Double = 44100

    // Smoothing: fast attack, slow decay for natural feel
    private let attackFactor: Float = 0.3
    private let decayFactor: Float = 0.12

    // MARK: - Private State

    private var smoothedBands: [Float] = Array(repeating: 0, count: 32)
    private var tapRef: MTAudioProcessingTap?
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length = 0
    private var halfN: Int = 0

    // Ring buffer for accumulating samples between FFT passes
    private var ringBuffer: [Float] = []
    private let ringLock = NSLock()

    // Update timer (~30fps)
    private var displayTimer: Timer?

    // MARK: - Init

    private init() {
        let n = fftSize
        log2n = vDSP_Length(log2(Float(n)))
        halfN = n / 2
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        ringBuffer.reserveCapacity(fftSize * 2)
    }

    deinit {
        removeTap()
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // MARK: - Public API

    /// Attach audio tap to the given player item's first audio track.
    func installTap(on playerItem: AVPlayerItem) {
        removeTap()

        guard let audioTrack = playerItem.asset.tracks(withMediaType: .audio).first else {
            return
        }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )

        guard status == noErr, let tap = tap else {
            return
        }

        tapRef = tap

        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        inputParams.audioTapProcessor = tapRef

        let mix = AVMutableAudioMix()
        mix.inputParameters = [inputParams]
        playerItem.audioMix = mix

        startDisplayTimer()
        DispatchQueue.main.async { self.isActive = true }
    }

    /// Remove the tap and stop publishing.
    func removeTap() {
        stopDisplayTimer()
        tapRef = nil

        ringLock.lock()
        ringBuffer.removeAll(keepingCapacity: true)
        ringLock.unlock()

        DispatchQueue.main.async {
            self.isActive = false
            withAnimation(.easeOut(duration: 0.5)) {
                self.bands = Array(repeating: 0, count: self.bandCount)
            }
            self.smoothedBands = Array(repeating: 0, count: self.bandCount)
        }
    }

    // MARK: - Display Timer (~30fps updates)

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.processPendingSamples()
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    // MARK: - FFT Processing

    /// Called from timer: pull samples from ring buffer and compute FFT.
    private func processPendingSamples() {
        ringLock.lock()
        guard ringBuffer.count >= fftSize else {
            ringLock.unlock()
            decayBands()
            return
        }
        let samples = Array(ringBuffer.prefix(fftSize))
        ringBuffer.removeFirst(min(fftSize / 2, ringBuffer.count))
        ringLock.unlock()

        guard let setup = fftSetup else { return }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var realPart = windowed
        var imagPart = [Float](repeating: 0, count: fftSize)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var complex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                vDSP_fft_zip(setup, &complex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&complex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        var scale = 2.0 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))

        let newBands = computeLogBands(magnitudes: magnitudes)
        updateSmoothedBands(newBands)
    }

    /// Map linear FFT magnitudes into log-spaced frequency bands.
    private func computeLogBands(magnitudes: [Float]) -> [Float] {
        let minFreq: Float = 20.0
        let maxFreq: Float = 20000.0
        var result = [Float](repeating: 0, count: bandCount)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let step = (logMax - logMin) / Float(bandCount)
        let freqPerBin = Float(sampleRate) / Float(fftSize)

        magnitudes.withUnsafeBufferPointer { magBuf in
            for i in 0..<bandCount {
                let freqLow = pow(10, logMin + Float(i) * step)
                let freqHigh = pow(10, logMin + Float(i + 1) * step)
                let binLow = Int(freqLow / freqPerBin)
                let binHigh = min(Int(freqHigh / freqPerBin), halfN - 1)
                guard binHigh >= binLow else { continue }

                var bandMag: Float = 0
                let count = vDSP_Length(binHigh - binLow + 1)
                vDSP_meanv(magBuf.baseAddress! + binLow, 1, &bandMag, count)

                let db = 10 * log10(max(bandMag, 1e-10))
                result[i] = max(0, min(1, (db + 80) / 80))
            }
        }

        return result
    }

    /// Apply attack/decay smoothing.
    private func updateSmoothedBands(_ newBands: [Float]) {
        for i in 0..<bandCount {
            if newBands[i] > smoothedBands[i] {
                smoothedBands[i] = smoothedBands[i] * (1 - attackFactor) + newBands[i] * attackFactor
            } else {
                smoothedBands[i] = smoothedBands[i] * (1 - decayFactor) + newBands[i] * decayFactor
            }
        }

        let snapshot = smoothedBands
        DispatchQueue.main.async { [weak self] in
            self?.bands = snapshot
        }
    }

    /// Decay all bands toward zero (called when buffer is sparse).
    private func decayBands() {
        var changed = false
        for i in 0..<bandCount where smoothedBands[i] > 0.001 {
            smoothedBands[i] *= (1 - decayFactor)
            changed = true
        }
        if changed {
            let snapshot = smoothedBands
            DispatchQueue.main.async { [weak self] in
                self?.bands = snapshot
            }
        }
    }

    // MARK: - Sample Ingestion (called from tap process callback)

    fileprivate func ingestSamples(_ samples: [Float]) {
        ringLock.lock()
        ringBuffer.append(contentsOf: samples)
        // Cap ring buffer to avoid unbounded growth
        if ringBuffer.count > fftSize * 4 {
            ringBuffer.removeFirst(ringBuffer.count - fftSize * 4)
        }
        ringLock.unlock()
    }
}

// MARK: - MTAudioProcessingTap C Callbacks

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {}

private func tapUnprepare(tap: MTAudioProcessingTap) {}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    // Pass audio through unchanged
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        nil,
        numberFramesOut
    )

    guard status == noErr else { return }

    // Extract engine reference
    let clientInfo = MTAudioProcessingTapGetStorage(tap)
    let engine = Unmanaged<AudioVisualizerEngine>.fromOpaque(clientInfo).takeUnretainedValue()

    // Read PCM samples from the first audio buffer
    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    guard let firstBuffer = bufferList.first,
          let data = firstBuffer.mData else { return }

    let frameCount = Int(numberFramesOut.pointee)
    let channelCount = Int(firstBuffer.mNumberChannels)

    // Mix channels down to mono
    let floatData = data.bindMemory(to: Float.self, capacity: frameCount * channelCount)
    var monoSamples = [Float](repeating: 0, count: frameCount)

    if channelCount > 1 {
        for frame in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channelCount {
                sum += floatData[frame * channelCount + ch]
            }
            monoSamples[frame] = sum / Float(channelCount)
        }
    } else {
        monoSamples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
    }

    engine.ingestSamples(monoSamples)
}
