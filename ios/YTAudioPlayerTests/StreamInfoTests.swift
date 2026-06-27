//
//  StreamInfoTests.swift
//  YTAudioPlayerTests
//
//  S3-4 fix verification: StreamInfo.replayGain is the optional dB
//  value from the backend. It must:
//  1. Default to nil when the JSON doesn't include the field
//  2. Round-trip when present
//  3. Be Equatable by value (so QueueItem equality holds)
//
//  Reference: project-playback-gap-analysis-2026-06-16.md, S3-4
//

import XCTest
@testable import PeacePlayer

final class StreamInfoTests: XCTestCase {

    func testDecode_withoutReplayGain_isNil() {
        // Older backend responses (and the in-app cache) may not include
        // the replayGain field. The decoder must treat missing key as nil,
        // not throw.
        let json = """
        {
          "streamUrl": "https://example.com/stream.m4a",
          "mimeType": "audio/mp4",
          "bitrate": 160000
        }
        """

        let data = json.data(using: .utf8)!
        let info = try? JSONDecoder().decode(StreamInfo.self, from: data)

        XCTAssertNotNil(info)
        XCTAssertNil(info?.replayGain, "Missing replayGain should decode as nil, not throw")
    }

    func testDecode_withReplayGain_isSet() {
        let json = """
        {
          "streamUrl": "https://example.com/stream.m4a",
          "mimeType": "audio/mp4",
          "bitrate": 160000,
          "replayGain": -7.5
        }
        """

        let data = json.data(using: .utf8)!
        let info = try? JSONDecoder().decode(StreamInfo.self, from: data)

        XCTAssertEqual(info?.replayGain, -7.5)
    }

    func testDecode_withZeroReplayGain_isSet() {
        // 0 dB is a valid (no-change) gain, distinct from "no data".
        // Must not be conflated with the UserDefaults "no value" sentinel.
        let json = """
        {
          "streamUrl": "https://example.com/stream.m4a",
          "mimeType": "audio/mp4",
          "bitrate": 160000,
          "replayGain": 0
        }
        """

        let data = json.data(using: .utf8)!
        let info = try? JSONDecoder().decode(StreamInfo.self, from: data)

        XCTAssertEqual(info?.replayGain, 0, "0 dB should decode as 0, not nil")
    }

    func testDecode_withPositiveReplayGain_isSet() {
        // Some tracks are quieter than the reference level; positive
        // gains (boosts) are valid.
        let json = """
        {
          "streamUrl": "https://example.com/stream.m4a",
          "mimeType": "audio/mp4",
          "bitrate": 160000,
          "replayGain": 3.2
        }
        """

        let data = json.data(using: .utf8)!
        let info = try? JSONDecoder().decode(StreamInfo.self, from: data)

        XCTAssertEqual(info?.replayGain, 3.2)
    }
}
