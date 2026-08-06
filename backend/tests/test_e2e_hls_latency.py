#!/usr/bin/env python3
"""
End-to-end test for the HLS latency fix.

This script simulates the exact API calls the iOS app makes when playing
a track. It exercises both the cold-play HLS path and the warm-play
/audio path, plus the edge cases the iOS app hits (auth, Range
requests, missing segments, etc.).

It does NOT drive the actual iOS UI. For that, see the iOS simctl
driver (test 7 below). This script verifies the backend behaves
correctly for every API call the iOS app makes.

Run:  ./venv/bin/python tests/test_e2e_hls_latency.py
"""

import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional

BASE_URL = "http://localhost:8181"
JWT_PATH = "/tmp/test_jwt.txt"
USER_ID = "5db0e11c-c963-444a-9ead-91b80129d89e"
JWT_SECRET = "A2FoQd2xp2EaHX3eBtur7WA9jET5c_NFTPqMjtN2ikfU4oH3EPFd5NbQWAOqOlLE"

# ANSI colors (skipped if not a TTY)
def _color(s, code): return f"\033[{code}m{s}\033[0m" if sys.stdout.isatty() else s
GREEN, RED, YELLOW, CYAN, BOLD = (
    lambda s: _color(s, "32"),
    lambda s: _color(s, "31"),
    lambda s: _color(s, "33"),
    lambda s: _color(s, "36"),
    lambda s: _color(s, "1"),
)


class TestStats:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.failures = []

    def record(self, name, ok, detail=""):
        if ok is True:
            self.passed += 1
            print(f"  {GREEN('✓')} {name}")
        elif ok is None:
            self.skipped += 1
            print(f"  {YELLOW('⊘')} {name}  {YELLOW(detail)}")
        else:
            self.failed += 1
            self.failures.append((name, detail))
            print(f"  {RED('✗')} {name}")
            if detail:
                for line in str(detail).splitlines():
                    print(f"      {line}")

    def summary(self):
        total = self.passed + self.failed + self.skipped
        print()
        print(BOLD("=" * 70))
        print(BOLD(f"Results: {self.passed}/{total} passed"
                   + (f", {self.failed} failed" if self.failed else "")
                   + (f", {self.skipped} skipped" if self.skipped else "")))
        print(BOLD("=" * 70))
        if self.failures:
            print()
            print(RED("Failed tests:"))
            for name, detail in self.failures:
                print(f"  {RED('•')} {name}")
                for line in str(detail).splitlines()[:5]:
                    print(f"      {line}")


S = TestStats()


# ---------- helpers ----------

def mint_jwt() -> str:
    """Mint a fresh JWT for testing."""
    import jwt
    now = int(time.time())
    payload = {
        "sub": USER_ID,
        "apple_sub": "test-apple-sub",
        "iat": now,
        "exp": now + 30 * 24 * 3600,
        "iss": "peaceplayer",
    }
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")


def get_jwt() -> str:
    """Return the cached test JWT, minting a fresh one if missing."""
    if not os.path.exists(JWT_PATH):
        with open(JWT_PATH, "w") as f:
            f.write(mint_jwt())
    with open(JWT_PATH) as f:
        return f.read().strip()


def http(method: str, path: str, *, headers=None, body=None, timeout=30):
    """Make an HTTP request. Returns (status_code, headers, body_bytes).
    Headers are lowercased to match urllib's behavior."""
    headers = headers or {}
    if body is not None and isinstance(body, (dict, list)):
        body = json.dumps(body).encode("utf-8")
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(
        BASE_URL + path, data=body, method=method, headers=headers
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            # urllib lowercases all header names; normalize to lowercase here
            return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
    except urllib.error.URLError as e:
        return 0, {}, str(e).encode()


def assert_eq(actual, expected, msg=""):
    if actual != expected:
        raise AssertionError(f"{msg}: expected {expected!r}, got {actual!r}")


def assert_true(cond, msg=""):
    if not cond:
        raise AssertionError(msg or "expected truthy")


def assert_in(needle, haystack, msg=""):
    if needle not in haystack:
        raise AssertionError(
            f"{msg}: {needle!r} not in {haystack[:200]!r}"
        )


def elapsed_ms(start):
    return int((time.monotonic() - start) * 1000)


def section(name):
    print()
    print(BOLD(CYAN(f"── {name} ──")))


# ---------- find a track ----------

def find_track(query: str) -> dict:
    """Search for a track and return the first result with a videoId."""
    status, _, body = http(
        "POST", "/search",
        headers={"Authorization": f"Bearer {get_jwt()}"},
        body={"query": query, "limit": 5},
    )
    assert_eq(status, 200, f"search for {query!r}")
    data = json.loads(body)
    tracks = data if isinstance(data, list) else data.get("data", [])
    for t in tracks:
        if t.get("videoId"):
            return t
    raise AssertionError(f"no tracks with videoId for {query!r}")


# ---------- Test 1: cold play (HLS path) ----------

def test_cold_play_hls():
    section("Test 1: Cold play (HLS path) — search → /stream → /play → segments")
    jwt = get_jwt()

    # Step 1: search for a track that's not in the local cache
    print(f"  {CYAN('Step 1: search for a not-yet-cached track')}")
    track = find_track("Pink Floyd Comfortably Numb")
    print(f"    found: {track['videoId']} — {track['title']} ({track['durationSeconds']}s)")
    video_id = track["videoId"]

    # Sanity: ensure the audio_cache doesn't exist (else we'd be testing warm path)
    cache_path = Path(f"/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache/{video_id}.m4a")
    if cache_path.exists():
        print(f"    {YELLOW('(removing pre-existing cache file for clean cold test)')}")
        cache_path.unlink()

    # Step 2: /stream — should return /play HLS URL (cold)
    print(f"  {CYAN('Step 2: GET /stream (iOS getStreamUrl equivalent)')}")
    t = time.monotonic()
    status, _, body = http("GET", f"/stream/{video_id}",
                           headers={"Authorization": f"Bearer {jwt}"})
    ms = elapsed_ms(t)
    assert_eq(status, 200, "/stream status")
    S.record(f"/stream returns 200 in {ms}ms (< 30s iOS timeout)", ms < 30_000,
             f"took {ms}ms")
    info = json.loads(body)
    stream_url = info["streamUrl"]
    mime = info["mimeType"]
    assert_in("/play/", stream_url, "stream URL should be /play/ for cold")
    assert_eq(mime, "application/x-mpegurl", "mime type for HLS")
    S.record("/stream returns HLS URL for cold play", True)

    # Step 3: GET /play/playlist.m3u8 — should return immediately
    print(f"  {CYAN('Step 3: GET /play/playlist.m3u8?token=... (placeholder or real)')}")
    t = time.monotonic()
    status, hdrs, body = http("GET", stream_url)
    ms = elapsed_ms(t)
    assert_eq(status, 200, "playlist.m3u8 status")
    S.record(f"playlist.m3u8 returns 200 in {ms}ms (was up to 30s + 504)", ms < 1000,
             f"took {ms}ms")
    m3u8_text = body.decode("utf-8", errors="replace")
    assert_in("#EXTM3U", m3u8_text, "valid m3u8 header")
    assert_in("EXT-X-MAP", m3u8_text, "m3u8 references init.mp4")
    S.record("m3u8 body is well-formed (EXTM3U + EXT-X-MAP)", True)

    # Step 4: poll for HLS to start producing segments
    print(f"  {CYAN('Step 4: poll for HLS transcode to produce first segment')}")
    hls_dir = Path(f"/Users/coderbat/iYMusic/YTAudioSystem/backend/data/hls/{video_id}")
    deadline = time.monotonic() + 30  # 30s budget for first segment
    first_seen_at_ms = None
    while time.monotonic() < deadline:
        if (hls_dir / "seg_000.m4s").exists():
            first_seen_at_ms = int((deadline - time.monotonic() + 30) * 1000)
            # Actually, we want elapsed since this test started
            first_seen_at_ms = int((time.monotonic() - (deadline - 30)) * 1000)
            break
        time.sleep(0.2)
    assert_true(first_seen_at_ms is not None,
                f"first segment did not appear within 30s; HLS dir: {hls_dir}")
    S.record(f"first HLS segment appeared in {first_seen_at_ms}ms", True)

    # Step 5: GET /play/init.mp4
    print(f"  {CYAN('Step 5: GET /play/init.mp4?token=...')}")
    init_url = stream_url.replace("playlist.m3u8", "init.mp4")
    status, hdrs, body = http("GET", init_url)
    assert_eq(status, 200, "init.mp4 status")
    assert_true(len(body) > 100, f"init.mp4 too small: {len(body)} bytes")
    S.record(f"init.mp4 returns 200 + {len(body)} bytes (fMP4 init segment)", True)

    # Step 6: GET /play/seg_000.m4s
    print(f"  {CYAN('Step 6: GET /play/seg_000.m4s?token=...')}")
    seg_url = stream_url.replace("playlist.m3u8", "seg_000.m4s")
    t = time.monotonic()
    status, hdrs, body = http("GET", seg_url)
    ms = elapsed_ms(t)
    assert_eq(status, 200, "seg_000.m4s status")
    S.record(f"seg_000.m4s returns 200 in {ms}ms, {len(body)} bytes", True)

    # Step 7: GET /play/seg_999.m4s (nonexistent) — should be 503 with Retry-After
    print(f"  {CYAN('Step 7: GET /play/seg_999.m4s?token=... (nonexistent)')}")
    bad_url = stream_url.replace("playlist.m3u8", "seg_999.m4s")
    status, hdrs, body = http("GET", bad_url)
    assert_eq(status, 503, "nonexistent segment should 503")
    assert_in("retry-after", hdrs, "503 should have Retry-After")
    S.record("nonexistent segment returns 503 + Retry-After (AVPlayer retries)", True)

    # Step 8: re-fetch m3u8 — should have grown (real playlist with segments)
    print(f"  {CYAN('Step 8: re-fetch m3u8 — should now have real segments')}")
    status, _, body = http("GET", stream_url)
    m3u8_text = body.decode("utf-8", errors="replace")
    segment_count = m3u8_text.count(".m4s?")
    assert_true(segment_count > 0, "real m3u8 should reference at least one segment")
    S.record(f"re-fetched m3u8 has {segment_count} segment references", True)


# ---------- Test 2: warm play (/audio path) ----------

def test_warm_play_audio():
    section("Test 2: Warm play (/audio path) — Range requests, valid MP4")
    jwt = get_jwt()

    # Use a track that's already in the cache (from earlier tests)
    cache_files = sorted(
        Path("/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache").glob("*.m4a"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    assert_true(len(cache_files) > 0, "need at least one cached track for warm test")
    track = cache_files[0]
    video_id = track.stem
    size = track.stat().st_size
    print(f"  using cached track: {video_id} ({size} bytes)")

    # Step 1: /stream — should return /audio URL (warm)
    print(f"  {CYAN('Step 1: GET /stream (warm path)')}")
    t = time.monotonic()
    status, _, body = http("GET", f"/stream/{video_id}",
                           headers={"Authorization": f"Bearer {jwt}"})
    ms = elapsed_ms(t)
    assert_eq(status, 200, "/stream status")
    info = json.loads(body)
    assert_in("/audio/", info["streamUrl"], "warm path should return /audio URL")
    assert_eq(info["mimeType"], "audio/mp4", "warm mime type")
    S.record(f"/stream returns /audio URL in {ms}ms (cache hit)", True)

    # Step 2: GET /audio — full file
    print(f"  {CYAN('Step 2: GET /audio/{videoId}.m4a (full file)')}")
    audio_url = f"/audio/{video_id}.m4a?token={jwt}"
    status, hdrs, body = http("GET", audio_url)
    assert_eq(status, 200, "/audio full status")
    assert_true(len(body) > 100_000, f"audio file too small: {len(body)} bytes")
    S.record(f"/audio returns 200 + {len(body)} bytes (full file)", True)

    # Step 3: GET /audio with Range header (iOS seek bar)
    print(f"  {CYAN('Step 3: GET /audio with Range: bytes=0-65535 (AVPlayer initial probe)')}")
    status, hdrs, body = http(
        "GET", f"/audio/{video_id}.m4a?token={jwt}",
        headers={"Range": "bytes=0-65535"},
    )
    assert_eq(status, 206, "Range request should be 206 Partial Content")
    assert_eq(hdrs.get("content-length"), "65536", "Range Content-Length")
    assert_true("content-range" in hdrs, "Range response has Content-Range")
    S.record("Range request returns 206 with correct headers", True)

    # Step 4: verify the file has both ftyp and moov atoms (AVPlayer needs moov)
    print(f"  {CYAN('Step 4: verify cached file has moov atom (AVPlayer requirement)')}")
    ftyp_at = body.find(b"ftyp")
    moov_at = body.find(b"moov")
    assert_true(ftyp_at >= 0, "ftyp atom missing")
    assert_true(moov_at >= 0, "moov atom missing (AVPlayer needs this to know duration)")
    S.record("cached file has both ftyp + moov atoms (valid MP4)", True)


# ---------- Test 3: cache check edge cases ----------

def test_cache_check_edge_cases():
    section("Test 3: Cache check edge cases (1KB / 50KB / 100KB)")
    jwt = get_jwt()

    # Use a videoId that exists in the stream URL cache
    # (we use one from the previous test, which we streamed)
    # Easiest: search for any track, then it will be stream-cached
    track = find_track("Pink Floyd Time")
    video_id = track["videoId"]
    cache_path = Path(f"/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache/{video_id}.m4a")
    original = cache_path.read_bytes() if cache_path.exists() else None

    try:
        # 1KB → /play
        print(f"  {CYAN('1KB file → /play')}")
        cache_path.write_bytes(b"\x00" * 1024)
        status, _, body = http("GET", f"/stream/{video_id}",
                               headers={"Authorization": f"Bearer {jwt}"})
        info = json.loads(body)
        assert_in("/play/", info["streamUrl"], "1KB should route to /play")
        S.record("1KB cache file routes to /play (HLS)", True)

        # 49KB → /play (just under threshold)
        print(f"  {CYAN('49KB file → /play (just under 50KB threshold)')}")
        cache_path.write_bytes(b"\x00" * 49_000)
        status, _, body = http("GET", f"/stream/{video_id}",
                               headers={"Authorization": f"Bearer {jwt}"})
        info = json.loads(body)
        assert_in("/play/", info["streamUrl"], "49KB should route to /play")
        S.record("49KB file routes to /play (HLS) — threshold holds", True)

        # 50KB+1 → /audio (just over threshold; the check is `> 50_000`)
        print(f"  {CYAN('50,001 bytes → /audio (just over threshold)')}")
        cache_path.write_bytes(b"\x00" * 50_001)
        status, _, body = http("GET", f"/stream/{video_id}",
                               headers={"Authorization": f"Bearer {jwt}"})
        info = json.loads(body)
        assert_in("/audio/", info["streamUrl"], "50,001 bytes should route to /audio")
        S.record("50,001 bytes routes to /audio (just over threshold)", True)

        # 100KB → /audio
        print(f"  {CYAN('100KB file → /audio')}")
        cache_path.write_bytes(b"\x00" * 100_000)
        status, _, body = http("GET", f"/stream/{video_id}",
                               headers={"Authorization": f"Bearer {jwt}"})
        info = json.loads(body)
        assert_in("/audio/", info["streamUrl"], "100KB should route to /audio")
        S.record("100KB file routes to /audio (warm)", True)

        # No file → /play
        print(f"  {CYAN('No file → /play')}")
        cache_path.unlink()
        status, _, body = http("GET", f"/stream/{video_id}",
                               headers={"Authorization": f"Bearer {jwt}"})
        info = json.loads(body)
        assert_in("/play/", info["streamUrl"], "no file should route to /play")
        S.record("no cache file routes to /play (HLS)", True)

    finally:
        # Restore original
        if original is not None:
            cache_path.write_bytes(original)
        elif cache_path.exists():
            cache_path.unlink()


# ---------- Test 4: HLS event-style polling ----------

def test_hls_polling():
    section("Test 4: HLS event-style polling (rapid m3u8 re-fetch)")
    jwt = get_jwt()

    # Find a track that we'll start an HLS transcode for
    track = find_track("Pink Floyd Money")
    video_id = track["videoId"]
    stream_url = f"/play/{video_id}/playlist.m3u8?token={jwt}"

    # Start a fresh HLS by hitting /play (this also starts the worker)
    print(f"  {CYAN('Step 1: GET /play/playlist.m3u8 to start HLS transcode')}")
    t = time.monotonic()
    status, _, body = http("GET", stream_url)
    ms = elapsed_ms(t)
    assert_eq(status, 200, "first playlist fetch")
    # First m3u8 fetch can include yt-dlp URL extraction (5-10s on cold cache).
    # The key invariant is that it returns < 30s (iOS timeout budget).
    S.record(f"first m3u8 fetch in {ms}ms (under 30s iOS budget)", ms < 30_000,
             f"took {ms}ms")

    # Poll aggressively like AVPlayer does (every 1s for up to 30s)
    # The transcode may take a while if other transcodes are queued
    # (global semaphore cap=3).
    print(f"  {CYAN('Step 2: poll m3u8 every 1s for up to 30s (simulating AVPlayer)')}")
    poll_results = []
    saw_segments = False
    for i in range(30):
        status, _, body = http("GET", stream_url)
        m3u8 = body.decode("utf-8", errors="replace")
        segs = m3u8.count(".m4s?")
        poll_results.append((i, status, segs))
        if segs > 0 and not saw_segments:
            print(f"    first segments seen at poll #{i} ({segs} segments)")
            saw_segments = True
        if saw_segments and i > 0 and poll_results[i][2] >= poll_results[i-1][2]:
            # Have segments and they're not decreasing — we can stop
            # (we already saw at least one grow or stay)
            pass
        time.sleep(1)

    # Verify all polls returned 200 (no AVPlayer retry storm)
    all_200 = all(r[1] == 200 for r in poll_results)
    S.record(f"all {len(poll_results)} polls returned 200 (no retry storm)", all_200)

    # Verify segments eventually appeared
    final_segs = poll_results[-1][2]
    assert_true(final_segs > 0,
                f"segments should appear within 30s polling: final={final_segs}")
    S.record(f"segments eventually appear (final: {final_segs})", True)

    # Verify init.mp4 and a segment are accessible
    print(f"  {CYAN('Step 3: verify init.mp4 + seg_000.m4s are fetchable')}")
    status, _, body = http("GET", stream_url.replace("playlist.m3u8", "init.mp4"))
    assert_eq(status, 200, "init.mp4 fetchable")
    S.record(f"init.mp4 fetchable (200, {len(body)} bytes)", True)

    status, _, body = http("GET", stream_url.replace("playlist.m3u8", "seg_000.m4s"))
    assert_eq(status, 200, "seg_000.m4s fetchable")
    S.record(f"seg_000.m4s fetchable (200, {len(body)} bytes)", True)


# ---------- Test 5: auth ----------

def test_auth():
    section("Test 5: Auth (no token, bad token)")
    # No token
    print(f"  {CYAN('No Authorization header')}")
    status, _, _ = http("GET", "/stream/anything")
    assert_eq(status, 401, "no auth → 401")
    S.record("missing token returns 401", True)

    # Bad token
    print(f"  {CYAN('Invalid Bearer token')}")
    status, _, _ = http("GET", "/stream/anything",
                        headers={"Authorization": "Bearer not-a-real-jwt"})
    assert_eq(status, 401, "bad token → 401")
    S.record("invalid token returns 401", True)

    # Good token (but bogus videoId)
    print(f"  {CYAN('Valid token, non-existent videoId')}")
    status, _, body = http("GET", "/stream/_does_not_exist_",
                           headers={"Authorization": f"Bearer {get_jwt()}"})
    assert_eq(status, 404, "no track → 404")
    S.record("valid token + missing track returns 404", True)


# ---------- Test 6: iOS timeout budget ----------

def test_ios_timeout_budget():
    section("Test 6: iOS timeout budget — /stream completes in <30s for all paths")
    jwt = get_jwt()

    # Cold play (no cache) — should be fast because /stream is just cache lookups
    print(f"  {CYAN('Cold play /stream timing')}")
    # Use a unique videoId that has no cache, to ensure cold path
    track = find_track("Pink Floyd Another Brick in the Wall")
    video_id = track["videoId"]
    cache_path = Path(f"/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache/{video_id}.m4a")
    if cache_path.exists():
        cache_path.unlink()
    # Also clean up any leftover HLS
    hls_dir = Path(f"/Users/coderbat/iYMusic/YTAudioSystem/backend/data/hls/{video_id}")
    if hls_dir.exists():
        import shutil
        shutil.rmtree(hls_dir)
    # Drop the stream URL cache so we measure cold path
    # (yt-dlp is cached in-process; the stream_cache module is in-memory, so
    # we can't easily drop it from here. But the stream cache has a 3.5h TTL
    # so a fresh search → fresh stream URL is the realistic cold path.)

    t = time.monotonic()
    status, _, body = http("GET", f"/stream/{video_id}",
                           headers={"Authorization": f"Bearer {jwt}"})
    ms = elapsed_ms(t)
    assert_eq(status, 200, "/stream cold")
    info = json.loads(body)
    assert_in("/play/", info["streamUrl"], "cold routes to /play")
    S.record(f"cold /stream completes in {ms}ms (iOS 30s timeout)", ms < 30_000,
             f"took {ms}ms")

    # Now follow the HLS path end-to-end like iOS would
    print(f"  {CYAN('Full cold-play path: /play m3u8 + init.mp4 + seg_000.m4s')}")
    stream_url = info["streamUrl"]
    t = time.monotonic()
    status, _, body = http("GET", stream_url)
    m3u8_ms = elapsed_ms(t)
    assert_eq(status, 200, "m3u8")
    S.record(f"m3u8 in {m3u8_ms}ms", True)

    # Wait for first segment
    deadline = time.monotonic() + 20
    first_seg_seen = None
    while time.monotonic() < deadline:
        if (hls_dir / "seg_000.m4s").exists():
            first_seg_seen = True
            break
        time.sleep(0.2)
    first_seg_total_ms = int((time.monotonic() - (deadline - 20)) * 1000)
    assert_true(first_seg_seen, "first segment did not appear within 20s")
    S.record(f"first segment in {first_seg_total_ms}ms (from start of cold play)",
             True)

    # Total budget: /stream + m3u8 + first_segment
    total_ms = m3u8_ms + first_seg_total_ms
    S.record(f"total cold-play budget: ~{total_ms}ms (well under 30s)", total_ms < 30_000)


# ---------- main ----------

def main():
    print(BOLD(CYAN("iYMusic E2E HLS Latency Test")))
    print(BOLD(f"Backend: {BASE_URL}"))
    print(BOLD(f"JWT: {JWT_PATH}"))
    print()

    # Check backend is up
    try:
        status, _, body = http("GET", "/health", timeout=5)
        assert_eq(status, 200, "backend health check")
        health = json.loads(body)
        print(f"Backend up: {health.get('status')} (uptime: {health.get('uptime_seconds')}s, "
              f"youtube: {health.get('youtube')})")
    except Exception as e:
        print(RED(f"Backend not reachable: {e}"))
        print(RED("Start the backend first: launchctl kickstart -k gui/$(id -u)/com.peaceplayer.backend"))
        sys.exit(1)

    try:
        test_cold_play_hls()
        test_warm_play_audio()
        test_cache_check_edge_cases()
        test_hls_polling()
        test_auth()
        test_ios_timeout_budget()
    except AssertionError as e:
        S.failed += 1
        S.failures.append(("UNCAUGHT ASSERTION", str(e)))
        print(RED(f"UNCAUGHT: {e}"))
    except Exception as e:
        S.failed += 1
        S.failures.append(("UNCAUGHT EXCEPTION", str(e)))
        print(RED(f"UNCAUGHT EXCEPTION: {e}"))

    S.summary()
    sys.exit(0 if S.failed == 0 else 1)


if __name__ == "__main__":
    main()
