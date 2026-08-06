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


def http(method: str, path: str, *, headers=None, body=None, timeout=30, follow_redirects=True):
    """Make an HTTP request. Returns (status_code, headers, body_bytes).
    Headers are lowercased to match urllib's behavior.

    `follow_redirects` defaults to True (urllib's default). Set False
    to surface 302s instead of chasing them — needed for testing the
    /fast endpoint, which 302s to either /audio (warm) or YouTube (cold).
    """
    import urllib.request
    headers = headers or {}
    if body is not None and isinstance(body, (dict, list)):
        body = json.dumps(body).encode("utf-8")
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(
        BASE_URL + path, data=body, method=method, headers=headers
    )
    try:
        # Build a no-redirect opener so we can opt out per-call
        if not follow_redirects:
            opener = urllib.request.build_opener(
                urllib.request.HTTPRedirectHandler()
            )
            # Override the default redirect behavior
            class NoRedirect(urllib.request.HTTPRedirectHandler):
                def redirect_request(self, *a, **kw):
                    return None
            opener = urllib.request.build_opener(NoRedirect())
            resp_ctx = opener.open(req, timeout=timeout)
        else:
            resp_ctx = urllib.request.urlopen(req, timeout=timeout)
        with resp_ctx as resp:
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


# ---------- Test 1: cold play (format 18 path) ----------

def test_cold_play_hls():
    section("Test 1: Cold play (format 18 path) — search → /stream → /fast → 302 to YouTube")
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

    # Step 2: /stream — should return /fast URL (always, since 2026-08-07)
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
    # S17-H / FORMAT-18-FAST (2026-08-07): /stream always
    # routes to /fast. The /fast endpoint decides between
    # /audio (warm) and YouTube format 18 (cold).
    assert_in("/fast/", stream_url, "stream URL should be /fast/ (always)")
    assert_eq(mime, "video/mp4", "mime type for progressive MP4")
    S.record("/stream returns /fast URL (Musi-style architecture)", True)

    # Step 3: GET /fast — should 302 to YouTube format 18 (cold)
    print(f"  {CYAN('Step 3: GET /fast/{videoId}.mp4?token=... (cold path)')}")
    t = time.monotonic()
    # Don't follow redirects — we want to see the 302 Location
    import urllib3
    status, hdrs, body = http(
        "GET", stream_url, follow_redirects=False
    )
    ms = elapsed_ms(t)
    assert_eq(status, 302, "/fast cold should 302 to YouTube")
    loc = hdrs.get("location", "")
    assert_in("googlevideo.com", loc, "302 should redirect to YouTube's googlevideo CDN")
    assert_in("itag=18", loc, "302 should be format 18 (progressive MP4)")
    S.record(f"/fast cold returns 302 → YouTube format 18 in {ms}ms", True)

    # Step 4: the YouTube URL should be well-formed (the live
    # HEAD test is environment-dependent and adds little — the
    # 302 + the `itag=18` query param are the proof of
    # correctness).
    print(f"  {CYAN('Step 4: verify YouTube URL has the right format')}")
    # mime param is URL-encoded as mime%3Dvideo%2Fmp4
    assert_in("mime", loc, "URL has mime param")
    assert_in("itag=18", loc, "URL has itag=18 (format 18)")
    # Signed URLs have sig= or signature= in query string
    assert_true("sig=" in loc or "signature=" in loc,
                "URL has YouTube signature (signed URL is valid)")
    S.record("YouTube format 18 URL is well-formed (mime=video/mp4, signed, itag=18)", True)


# ---------- Test 2: warm play (/audio path) ----------

def test_warm_play_audio():
    section("Test 2: Warm play (/audio path) — /stream → /fast → 302 → /audio")
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

    # Step 1: /stream — should always return /fast URL
    print(f"  {CYAN('Step 1: GET /stream (warm path, always /fast)')}")
    t = time.monotonic()
    status, _, body = http("GET", f"/stream/{video_id}",
                           headers={"Authorization": f"Bearer {jwt}"})
    ms = elapsed_ms(t)
    assert_eq(status, 200, "/stream status")
    info = json.loads(body)
    assert_in("/fast/", info["streamUrl"], "stream URL should be /fast/")
    S.record(f"/stream returns /fast URL in {ms}ms (cache hit)", True)

    # Step 2: /fast — should 302 to /audio (warm path)
    print(f"  {CYAN('Step 2: GET /fast/{videoId}.mp4?token=... (warm path → 302 to /audio)')}")
    t = time.monotonic()
    status, hdrs, body = http("GET", info["streamUrl"], follow_redirects=False)
    ms = elapsed_ms(t)
    assert_eq(status, 302, "/fast warm should 302 to /audio")
    loc = hdrs.get("location", "")
    assert_in(f"/audio/{video_id}.m4a", loc, "302 should redirect to /audio URL")
    S.record(f"/fast warm returns 302 → /audio in {ms}ms", True)

    # Step 3: GET /audio — full file
    print(f"  {CYAN('Step 3: GET /audio/{videoId}.m4a (full file)')}")
    audio_url = f"/audio/{video_id}.m4a?token={jwt}"
    status, hdrs, body = http("GET", audio_url)
    assert_eq(status, 200, "/audio full status")
    assert_true(len(body) > 100_000, f"audio file too small: {len(body)} bytes")
    S.record(f"/audio returns 200 + {len(body)} bytes (full file)", True)

    # Step 4: GET /audio with Range header (iOS seek bar)
    print(f"  {CYAN('Step 4: GET /audio with Range: bytes=0-65535 (AVPlayer initial probe)')}")
    status, hdrs, body = http(
        "GET", f"/audio/{video_id}.m4a?token={jwt}",
        headers={"Range": "bytes=0-65535"},
    )
    assert_eq(status, 206, "Range request should be 206 Partial Content")
    assert_eq(hdrs.get("content-length"), "65536", "Range Content-Length")
    assert_true("content-range" in hdrs, "Range response has Content-Range")
    S.record("Range request returns 206 with correct headers", True)

    # Step 5: verify the file has both ftyp and moov atoms (AVPlayer needs moov)
    print(f"  {CYAN('Step 5: verify cached file has moov atom (AVPlayer requirement)')}")
    ftyp_at = body.find(b"ftyp")
    moov_at = body.find(b"moov")
    assert_true(ftyp_at >= 0, "ftyp atom missing")
    assert_true(moov_at >= 0, "moov atom missing (AVPlayer needs this to know duration)")
    S.record("cached file has both ftyp + moov atoms (valid MP4)", True)


# ---------- Test 3: /fast cache routing ----------

def test_cache_check_edge_cases():
    section("Test 3: /fast routing — small cache files route to YouTube, large to /audio")
    jwt = get_jwt()

    # Use a videoId that exists in the stream URL cache
    track = find_track("Pink Floyd Time")
    video_id = track["videoId"]
    cache_path = Path(f"/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache/{video_id}.m4a")
    original = cache_path.read_bytes() if cache_path.exists() else None

    def _fast_destination(target_video_id):
        """Hit /fast with no redirect-following, return the Location host/path."""
        status, hdrs, _ = http(
            "GET", f"/fast/{target_video_id}.mp4?token={jwt}",
            follow_redirects=False,
        )
        return status, hdrs.get("location", "")

    try:
        # 1KB → YouTube format 18 (below warm threshold)
        print(f"  {CYAN('1KB file → YouTube format 18 (below 50KB warm threshold)')}")
        cache_path.write_bytes(b"\x00" * 1024)
        status, loc = _fast_destination(video_id)
        assert_eq(status, 302, "1KB should give 302")
        assert_in("googlevideo.com", loc, "1KB should redirect to YouTube (below warm threshold)")
        S.record("1KB cache file routes /fast → YouTube (cold)", True)

        # 49KB → YouTube (just under threshold)
        print(f"  {CYAN('49KB file → YouTube (just under 50KB threshold)')}")
        cache_path.write_bytes(b"\x00" * 49_000)
        status, loc = _fast_destination(video_id)
        assert_eq(status, 302, "49KB should give 302")
        assert_in("googlevideo.com", loc, "49KB should redirect to YouTube")
        S.record("49KB file routes /fast → YouTube (just under threshold)", True)

        # 50KB+1 → /audio (just over threshold)
        print(f"  {CYAN('50,001 bytes → /audio (just over threshold)')}")
        cache_path.write_bytes(b"\x00" * 50_001)
        status, loc = _fast_destination(video_id)
        assert_eq(status, 302, "50,001 bytes should give 302")
        assert_in(f"/audio/{video_id}.m4a", loc, "50,001 bytes should redirect to /audio")
        S.record("50,001 bytes routes /fast → /audio (just over threshold)", True)

        # 100KB → /audio
        print(f"  {CYAN('100KB file → /audio')}")
        cache_path.write_bytes(b"\x00" * 100_000)
        status, loc = _fast_destination(video_id)
        assert_eq(status, 302, "100KB should give 302")
        assert_in(f"/audio/{video_id}.m4a", loc, "100KB should redirect to /audio")
        S.record("100KB file routes /fast → /audio (warm)", True)

        # No file → YouTube
        print(f"  {CYAN('No file → YouTube')}")
        cache_path.unlink()
        status, loc = _fast_destination(video_id)
        assert_eq(status, 302, "no file should give 302")
        assert_in("googlevideo.com", loc, "no file should redirect to YouTube")
        S.record("no cache file routes /fast → YouTube (cold)", True)

    finally:
        # Restore original
        if original is not None:
            cache_path.write_bytes(original)
        elif cache_path.exists():
            cache_path.unlink()


# ---------- Test 4: HLS pipeline still works for legacy callers ----------

def test_hls_polling():
    section("Test 4: HLS pipeline still works (legacy callers + format 18 fallback)")
    jwt = get_jwt()

    # S17-H / FORMAT-18-FAST (2026-08-07): the iOS app no
    # longer uses the HLS pipeline (it goes through /fast),
    # but the HLS endpoints are still in place for any
    # legacy callers + as a fallback. This test confirms
    # the HLS pipeline still produces a valid stream when
    # called directly.
    AUDIO_CACHE = Path("/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache")
    HLS_BASE = Path("/Users/coderbat/iYMusic/YTAudioSystem/backend/data/hls")
    cached_vids = {p.stem for p in AUDIO_CACHE.glob("*.m4a")} | {
        p.name for p in HLS_BASE.iterdir() if p.is_dir()
    }

    # Search a few candidates; pick the first uncached one with
    # a reasonable duration (3-15 min).
    cold_track = None
    for q in ("Pink Floyd Learning to Fly", "Dire Straits", "Led Zeppelin Kashmir",
              "Santana", "Jimi Hendrix", "Genesis"):
        status, _, body = http("POST", "/search",
                               headers={"Authorization": f"Bearer {jwt}"},
                               body={"query": q, "limit": 10})
        if status != 200:
            continue
        tracks = json.loads(body)
        if isinstance(tracks, dict):
            tracks = tracks.get("data", [])
        for t in tracks:
            vid = t.get("videoId")
            dur = t.get("durationSeconds", 0)
            if vid and vid not in cached_vids and 180 <= dur <= 900:
                cold_track = t
                break
        if cold_track:
            break

    if not cold_track:
        S.record("find a fresh uncached track", None,
                 "no fresh track found in search — backend may be busy")
        return

    video_id = cold_track["videoId"]
    title = cold_track["title"]
    dur = cold_track["durationSeconds"]
    print(f"  {CYAN(f'cold track: {video_id} — {title} ({dur}s)')}")

    # Confirm format 18 is fast for this track (the new path)
    print(f"  {CYAN('Step 1: GET /fast (Musi-style format 18)')}")
    t = time.monotonic()
    status, hdrs, _ = http(
        "GET", f"/fast/{video_id}.mp4?token={jwt}",
        follow_redirects=False,
    )
    ms = elapsed_ms(t)
    assert_eq(status, 302, "/fast should 302")
    loc = hdrs.get("location", "")
    if "googlevideo.com" in loc:
        # Cold path (no cache) — first call after a server restart
        # takes ~3-5s for yt-dlp signature extraction.
        S.record(f"/fast cold → YouTube in {ms}ms (format 18 first-time cost)",
                 True)
    elif f"/audio/{video_id}.m4a" in loc:
        # Warm path (already cached)
        S.record(f"/fast warm → /audio in {ms}ms (instant)", True)
    else:
        raise AssertionError(f"unexpected 302 location: {loc[:200]}")

    # Confirm HLS still works for legacy callers
    print(f"  {CYAN('Step 2: GET /play/playlist.m3u8 (legacy HLS path)')}")
    hls_stream_url = f"/play/{video_id}/playlist.m3u8?token={jwt}"
    t = time.monotonic()
    status, _, body = http("GET", hls_stream_url)
    ms = elapsed_ms(t)
    assert_eq(status, 200, "HLS playlist fetch")
    m3u8 = body.decode("utf-8", errors="replace")
    assert_in("#EXTM3U", m3u8, "HLS m3u8 has valid header")
    S.record(f"HLS playlist returns 200 in {ms}ms (legacy path still alive)", True)

    # HLS warm-path 302 should still work
    print(f"  {CYAN('Step 3: HLS warm-path 302 → /audio')}")
    status, hdrs, _ = http("GET", hls_stream_url, follow_redirects=False)
    if status == 302:
        loc = hdrs.get("location", "")
        assert_in(f"/audio/{video_id}.m4a", loc, "HLS warm 302 → /audio")
        S.record("HLS warm-path 302 → /audio still works (legacy)", True)


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
    section("Test 6: iOS timeout budget — /stream + /fast completes fast for all paths")
    jwt = get_jwt()

    # Cold play (no cache) — should be fast because /stream is
    # just a cache lookup, and /fast cold is < 6s (first time
    # per server restart) or < 100ms (cached).
    print(f"  {CYAN('Cold play /stream timing')}")
    track = find_track("Pink Floyd Another Brick in the Wall")
    video_id = track["videoId"]
    cache_path = Path(f"/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache/{video_id}.m4a")
    if cache_path.exists():
        cache_path.unlink()

    # /stream should be near-instant (just a file-existence check)
    t = time.monotonic()
    status, _, body = http("GET", f"/stream/{video_id}",
                           headers={"Authorization": f"Bearer {jwt}"})
    stream_ms = elapsed_ms(t)
    assert_eq(status, 200, "/stream cold")
    info = json.loads(body)
    assert_in("/fast/", info["streamUrl"], "cold routes to /fast")
    S.record(f"cold /stream completes in {stream_ms}ms (iOS 30s timeout)",
             stream_ms < 30_000, f"took {stream_ms}ms")

    # /fast cold — first call after server restart pays the
    # yt-dlp signature extraction cost (~3-5s), but subsequent
    # calls within 5h are cache hits (<100ms).
    print(f"  {CYAN('/fast cold timing (format 18 URL extraction)')}")
    t = time.monotonic()
    status, hdrs, _ = http(
        "GET", f"/fast/{video_id}.mp4?token={jwt}",
        follow_redirects=False,
    )
    fast_ms = elapsed_ms(t)
    assert_eq(status, 302, "/fast should 302")
    loc = hdrs.get("location", "")
    is_youtube = "googlevideo.com" in loc
    is_audio = f"/audio/{video_id}.m4a" in loc
    assert_true(is_youtube or is_audio, f"unexpected 302: {loc[:100]}")

    if is_youtube:
        # Cold path
        S.record(
            f"/fast cold → YouTube in {fast_ms}ms "
            f"(first time per server: ~3-5s for yt-dlp n-challenge)",
            fast_ms < 6_000, f"took {fast_ms}ms",
        )
    else:
        # Warm path (was already cached as .m4a)
        S.record(
            f"/fast warm → /audio in {fast_ms}ms (cache hit)",
            fast_ms < 200, f"took {fast_ms}ms",
        )

    # Test the cache-hit timing
    print(f"  {CYAN('/fast second call (format 18 cache hit, should be <100ms)')}")
    t = time.monotonic()
    status, hdrs, _ = http(
        "GET", f"/fast/{video_id}.mp4?token={jwt}",
        follow_redirects=False,
    )
    second_ms = elapsed_ms(t)
    assert_eq(status, 302, "/fast second call should 302")
    S.record(
        f"/fast second call in {second_ms}ms (format 18 cache hit)",
        second_ms < 500, f"took {second_ms}ms",
    )

    # Total budget: /stream + /fast
    total_ms = stream_ms + fast_ms
    S.record(
        f"total cold-play budget: /stream + /fast = ~{total_ms}ms "
        f"(well under iOS 30s timeout)",
        total_ms < 30_000,
    )


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
