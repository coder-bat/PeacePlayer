#!/usr/bin/env python3
"""
Unit test for AudioExtractor.download_and_convert retry-on-403 logic.

v1.8.3 / YouTube-CDN-403-Retry: YouTube's CDN rate-limits
long-running connections from a single IP. After several
successful Range-chunked downloads, individual chunks can come
back as 403 Forbidden. The download_and_convert code path now
catches requests.exceptions.HTTPError, re-calls get_audio_info
for a fresh stream URL, and retries (up to 2 retries with 1-2s
backoff, 3 attempts total).

This test pins the contract:
  1. First attempt 403 → second attempt succeeds (with fresh URL)
  2. All 3 attempts 403 → download fails (None returned)
  3. First attempt 200 → no retry (single attempt path)
  4. Non-HTTP exception (e.g. ffmpeg failure) → no retry, returns None

If this test breaks, either:
  - The retry loop was refactored in a way that changes the
    attempt count (check the loop bound)
  - The HTTPError catch was widened/narrowed
  - The backoff was removed (test would slow down by 3+ seconds)

Runs in <5s — uses mock for get_audio_info and _download_stream.
No real YouTube calls.
"""

import sys
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch
from urllib.parse import quote

# Make sure we can import the backend module
sys.path.insert(
    0, str(Path(__file__).resolve().parents[1])
)

import requests
from extractor import AudioExtractor


class _FakeResponse:
    """Minimal stand-in for requests.Response with .status_code."""
    def __init__(self, status_code: int):
        self.status_code = status_code


def _make_403(url: str) -> requests.exceptions.HTTPError:
    """Build a 403 HTTPError that looks like one raised by
    r.raise_for_status() — i.e. has a .response.status_code."""
    resp = _FakeResponse(403)
    err = requests.exceptions.HTTPError(
        f"403 Client Error: Forbidden for url: {url[:60]}..."
    )
    err.response = resp
    return err


class DownloadRetryTests(unittest.TestCase):
    """Pin the retry-on-403 behavior of download_and_convert."""

    def setUp(self):
        from tempfile import TemporaryDirectory
        self.temp_directory = TemporaryDirectory(prefix="peaceplayer-extractor-")
        self.tmp = Path(self.temp_directory.name)
        self.ext = AudioExtractor(output_dir=str(self.tmp))
        self.video_id = "dQw4w9WgXcQ"
        self.metadata = {
            "title": "Test Track",
            "artists": ["Tester"],
            "album": "Test Album",
        }

    def tearDown(self):
        self.temp_directory.cleanup()

    @patch("extractor.time.sleep")  # skip real backoff
    def test_retry_after_403_then_success(self, mock_sleep):
        """First attempt raises 403, second attempt succeeds.
        download_and_convert should return the output_path."""
        # Each get_audio_info call returns a fresh stream_info dict
        # with a different URL — the retry path's intent is to fetch
        # a new URL after a 403.
        stream_urls = [
            "https://rr1.googlevideo.com/first-url",   # attempt 1 — 403
            "https://rr2.googlevideo.com/second-url",  # attempt 2 — success
        ]
        self.ext.get_audio_info = MagicMock(side_effect=[
            {"url": stream_urls[0], "ext": "webm"},
            {"url": stream_urls[1], "ext": "webm"},
        ])

        # _download_stream raises 403 on first call, succeeds on second
        call_count = {"n": 0}
        def fake_download(url, output_path):
            call_count["n"] += 1
            if call_count["n"] == 1:
                raise _make_403(url)
            # second call: no-op (just create a temp file so the
            # subsequent _convert_to_m4a mock has something to read)
            output_path.write_bytes(b"fake-audio")
        self.ext._download_stream = fake_download

        # _convert_to_m4a just creates the output file
        def fake_convert(input_path, output_path, metadata, quality):
            output_path.write_bytes(b"fake-m4a")
        self.ext._convert_to_m4a = fake_convert

        result = self.ext.download_and_convert(
            self.video_id, self.metadata
        )

        # Should have returned the output path (success after retry)
        self.assertIsNotNone(result)
        self.assertTrue(result.exists())
        # get_audio_info called twice (initial + 1 retry)
        self.assertEqual(self.ext.get_audio_info.call_count, 2)
        # _download_stream called twice (1 fail + 1 success)
        self.assertEqual(call_count["n"], 2)
        # Backoff was honored (1s on the 1 retry)
        self.assertEqual(mock_sleep.call_count, 1)
        mock_sleep.assert_called_with(1)

    @patch("extractor.time.sleep")
    def test_all_403s_give_up(self, mock_sleep):
        """All 3 attempts 403 → download fails (None returned)."""
        # Each retry gets a fresh URL (since the previous got 403'd)
        # but every download also gets 403'd.
        self.ext.get_audio_info = MagicMock(side_effect=[
            {"url": f"https://rr{i}.googlevideo.com/u", "ext": "webm"}
            for i in range(3)  # 3 attempts
        ])

        def always_403(url, output_path):
            raise _make_403(url)
        self.ext._download_stream = always_403

        result = self.ext.download_and_convert(
            self.video_id, self.metadata
        )

        # Should return None after exhausting retries
        self.assertIsNone(result)
        # All 3 attempts were made
        self.assertEqual(self.ext.get_audio_info.call_count, 3)
        # 2 backoff sleeps (after attempt 1 and 2)
        self.assertEqual(mock_sleep.call_count, 2)

    @patch("extractor.time.sleep")
    def test_first_attempt_success_no_retry(self, mock_sleep):
        """First attempt succeeds → no retry, no backoff."""
        self.ext.get_audio_info = MagicMock(return_value={
            "url": "https://rr1.googlevideo.com/u", "ext": "webm"
        })

        def fake_download(url, output_path):
            output_path.write_bytes(b"fake-audio")
        self.ext._download_stream = fake_download

        def fake_convert(input_path, output_path, metadata, quality):
            output_path.write_bytes(b"fake-m4a")
        self.ext._convert_to_m4a = fake_convert

        result = self.ext.download_and_convert(
            self.video_id, self.metadata
        )

        self.assertIsNotNone(result)
        # Only 1 get_audio_info call (no retry)
        self.assertEqual(self.ext.get_audio_info.call_count, 1)
        # No backoff (succeeded on first try)
        self.assertEqual(mock_sleep.call_count, 0)

    @patch("extractor.time.sleep")
    def test_non_http_error_does_not_retry(self, mock_sleep):
        """A non-HTTP exception (e.g. ffmpeg crash) should NOT trigger
        a retry — only 403s do."""
        self.ext.get_audio_info = MagicMock(return_value={
            "url": "https://rr1.googlevideo.com/u", "ext": "webm"
        })

        def fake_download(url, output_path):
            output_path.write_bytes(b"fake-audio")
        self.ext._download_stream = fake_download

        def fake_convert(input_path, output_path, metadata, quality):
            raise RuntimeError("ffmpeg exploded")
        self.ext._convert_to_m4a = fake_convert

        result = self.ext.download_and_convert(
            self.video_id, self.metadata
        )

        # Should return None
        self.assertIsNone(result)
        # Only 1 attempt — RuntimeError doesn't trigger retry
        self.assertEqual(self.ext.get_audio_info.call_count, 1)
        # No backoff
        self.assertEqual(mock_sleep.call_count, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
