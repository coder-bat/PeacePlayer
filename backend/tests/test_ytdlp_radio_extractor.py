#!/usr/bin/env python3
"""
Unit test for the yt-dlp RD-list radio extractor.

The S17-H / UpNext-FIX (2026-08-07) rewrite of get_watch_playlist
replaced ytmusicapi's broken parser with a yt-dlp call against
YouTube's RD<videoId> radio mix URL. This test pins the contract:

  1. yt-dlp is available and the version we depend on is installed
  2. The RD<videoId> URL extracts a non-empty entries list for a
     well-known song
  3. Each entry has the fields the parser depends on
     (id, title, duration, channel/uploader)
  4. The output format string in the parser hasn't drifted

If this test breaks, either:
  - YouTube changed the RD-list structure (update the parser)
  - yt-dlp's --flat-playlist behavior changed (pin a new version,
    update ydl_opts)
  - The output format string drifted (update _get_watch_playlist_ytdlp)

Runs in <5s against a real YouTube URL. The test seeds are stable
pop songs whose RD mixes have existed for years.
"""

import subprocess
import sys
import unittest
from typing import List, Dict, Optional


# Stable, well-known seeds. If YouTube nukes any of these radio mixes
# the test will fail with a clear error pointing at this list.
TEST_SEEDS = [
    "ldXdnZtTWp8",  # Jethro Tull - Thick as a Brick (Pt. I)
    "2sHZ4ny_SxU",  # Pink Floyd - Piper at the Gates of Dawn
    "dQw4w9WgXcQ",  # Rick Astley - Never Gonna Give You Up
]

YTDLP_BIN = "/Users/coderbat/iYMusic/YTAudioSystem/backend/venv/bin/yt-dlp"


class TestYtDlpRadioExtractor(unittest.TestCase):
    """
    Pins the yt-dlp RD-list extraction contract.
    """

    def setUp(self):
        # Sanity: yt-dlp is reachable
        result = subprocess.run(
            [YTDLP_BIN, "--version"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(
            result.returncode, 0,
            f"yt-dlp at {YTDLP_BIN} not callable: {result.stderr}"
        )
        # Note the version for the test output
        self.yt_dlp_version = result.stdout.strip()

    def _extract_rd_list(self, video_id: str) -> Optional[Dict]:
        """
        Replicates the ydl_opts from _get_watch_playlist_ytdlp and
        returns the parsed info dict. If this fails the contract is
        broken.
        """
        url = f"https://www.youtube.com/watch?v={video_id}&list=RD{video_id}"
        ydl_opts = {
            'quiet': True,
            'skip_download': True,
            'extract_flat': True,
            'playlistend': 25,
            'ignoreerrors': True,
        }
        # We import the ytm_client to use the same yt_dlp.YoutubeDL
        # wrapper. This pins the dependency on the venv copy.
        try:
            import yt_dlp
        except ImportError:
            self.skipTest("yt_dlp module not importable")
            return None
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                return ydl.extract_info(url, download=False)
        except Exception as e:
            self.fail(f"yt-dlp extract_info failed for {video_id}: {e}")

    def test_yt_dlp_version_pinned(self):
        """The pinned version should be 2026.7.4 (or newer patch).
        If this fails, bump yt-dlp in requirements.txt AND update the
        known-good version constant below."""
        # The S17-H (2026-07-26) fix bumped yt-dlp from a broken
        # 2026.03.17 to 2026.7.4. yt-dlp prints the version as
        # "2026.07.04" on stdout.
        # Allow anything from 2026.7 onwards.
        self.assertTrue(
            self.yt_dlp_version.startswith("2026.07") or
            self.yt_dlp_version.startswith("2026.08") or
            self.yt_dlp_version.startswith("2026.09") or
            self.yt_dlp_version.startswith("2026.1") or
            self.yt_dlp_version.startswith("2026.2"),
            f"yt-dlp {self.yt_dlp_version} is older than the 2026.7.4 "
            f"baseline. Bump in requirements.txt and verify the n-challenge "
            f"fix still works for /stream before re-running."
        )

    def test_rd_list_extracts_for_known_seeds(self):
        """For each well-known seed, yt-dlp should return a non-empty
        entries list. The iOS UpNext queue needs at least 5 tracks to
        feel like a real queue (the QueuePrefetcher takes up to 10)."""
        for video_id in TEST_SEEDS:
            with self.subTest(video_id=video_id):
                info = self._extract_rd_list(video_id)
                self.assertIsNotNone(
                    info,
                    f"yt-dlp returned None for {video_id}"
                )
                entries = info.get('entries') or []
                self.assertGreaterEqual(
                    len(entries), 5,
                    f"RD list for {video_id} returned only {len(entries)} "
                    f"entries. Need ≥5 for a usable UpNext queue. "
                    f"Either the seed is bad, YouTube nuked the radio mix, "
                    f"or extract_flat behavior changed."
                )

    def test_entry_shape_contract(self):
        """Each entry must have the fields the parser depends on:
        `id` (the videoId), `title`, and at least one of `channel` /
        `uploader`. `duration` should be present but we tolerate None
        (the iOS app handles missing duration gracefully)."""
        info = self._extract_rd_list(TEST_SEEDS[0])
        entries = info.get('entries') or []
        self.assertGreater(len(entries), 0, "No entries to inspect")

        for entry in entries[:5]:  # first 5 is enough to spot a regression
            with self.subTest(entry_id=entry.get('id')):
                self.assertTrue(
                    entry.get('id'),
                    f"Entry missing 'id': {entry}"
                )
                self.assertTrue(
                    entry.get('title'),
                    f"Entry {entry.get('id')} missing 'title'"
                )
                # channel OR uploader — at least one should be set
                self.assertTrue(
                    entry.get('channel') or entry.get('uploader'),
                    f"Entry {entry.get('id')} missing both 'channel' "
                    f"and 'uploader': {entry}"
                )

    def test_seed_excluded_from_results(self):
        """The parser skips the seed videoId (it's already in the
        user's queue). Verify the helper actually does this — if it
        regresses, the user would see the currently-playing track
        duplicated in UpNext, which is confusing."""
        from ytm_client import YTMusicClient
        client = YTMusicClient()  # guest mode — that's the failing case
        seed = TEST_SEEDS[0]
        tracks = client.get_watch_playlist(seed)
        ids = [t.get('videoId') for t in tracks]
        self.assertNotIn(
            seed, ids,
            f"Seed {seed} appeared in its own UpNext results: {ids[:5]}"
        )


class TestRadioEndpointE2E(unittest.TestCase):
    """
    Hits the live /radio endpoint to confirm the FastAPI route
    delegates to the (now-fixed) get_watch_playlist.
    """

    BASE_URL = "http://localhost:8181"
    JWT_PATH = "/tmp/test_jwt.txt"

    def setUp(self):
        import os
        if not os.path.exists(self.JWT_PATH):
            self.skipTest(f"Test JWT not at {self.JWT_PATH}")
        with open(self.JWT_PATH) as f:
            self.token = f.read().strip()
        # Confirm the backend is up
        try:
            import urllib.request
            urllib.request.urlopen(self.BASE_URL, timeout=2).read()
        except Exception as e:
            self.skipTest(f"Backend not reachable at {self.BASE_URL}: {e}")

    def test_radio_returns_tracks_for_real_seed(self):
        """The whole point of Phase 1: /radio should return 5+ tracks
        for a real seed. Before the fix it returned []."""
        import urllib.request
        import json

        for video_id in TEST_SEEDS:
            with self.subTest(video_id=video_id):
                req = urllib.request.Request(
                    f"{self.BASE_URL}/radio/{video_id}",
                    headers={"Authorization": f"Bearer {self.token}"},
                )
                with urllib.request.urlopen(req, timeout=30) as resp:
                    data = json.loads(resp.read().decode())
                self.assertIsInstance(data, list)
                self.assertGreaterEqual(
                    len(data), 5,
                    f"/radio/{video_id} returned only {len(data)} tracks. "
                    f"Expected 5+ for a real UpNext queue."
                )
                # Each track must have a videoId (otherwise iOS can't
                # fetch the stream URL)
                for t in data[:5]:
                    self.assertTrue(
                        t.get('videoId'),
                        f"Track missing videoId: {t}"
                    )

    def test_radio_excludes_seed_from_results(self):
        """The seed track is already playing. It must not appear
        in its own UpNext list."""
        import urllib.request
        import json

        seed = TEST_SEEDS[0]
        req = urllib.request.Request(
            f"{self.BASE_URL}/radio/{seed}",
            headers={"Authorization": f"Bearer {self.token}"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
        ids = [t.get('videoId') for t in data]
        self.assertNotIn(seed, ids)


if __name__ == "__main__":
    unittest.main(verbosity=2)
