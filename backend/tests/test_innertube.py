#!/usr/bin/env python3
"""
Offline tests for the InnerTube client (backend/innertube.py) and the
server paths that were switched to it on 2026-11-14.

Nothing here touches the network: the InnerTube HTTP calls are replaced
by hand-built player/search payloads, and the CDN download is driven
through a fake session.

What is pinned:
  1. InnerTube response parsing (visitorData, ytcfg, ytInitialData)
  2. Format selection: pre-signed URLs only, AAC ladder first
  3. resolve_stream() keeps the ytm_client.get_stream_url() contract
  4. resolve_audio() keeps the extractor.get_audio_info() contract
  5. Search maps a videoWithContextRenderer hit onto the TrackResponse
     contract the iOS app decodes strictly
  6. Chunked CDN download: 206-only, writes the file, raises otherwise
  7. ytm_client.get_stream_url() falls back to yt-dlp when InnerTube fails
  8. /search uses InnerTube first and ytmusicapi second

Run: cd backend && venv/bin/python -m pytest tests/test_innertube.py -q
"""

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import innertube  # noqa: E402


# --------------------------------------------------------------------------
# fixtures / sample payloads
# --------------------------------------------------------------------------

PLAYER_RESPONSE = {
    "playabilityStatus": {"status": "OK"},
    "videoDetails": {"title": "Test Track", "lengthSeconds": "212"},
    "streamingData": {
        "expiresInSeconds": 21600,
        "adaptiveFormats": [
            {
                "itag": 140,
                "url": "https://r1.googlevideo.com/videoplayback?exp=1&sig=A",
                "mimeType": 'audio/mp4; codecs="mp4a.40.2"',
                "bitrate": 129000,
                "contentLength": "3400000",
                "audioSampleRate": "44100",
            },
            {
                "itag": 139,
                "url": "https://r1.googlevideo.com/videoplayback?exp=1&sig=B",
                "mimeType": 'audio/mp4; codecs="mp4a.40.5"',
                "bitrate": 49000,
                "contentLength": "1300000",
                "audioSampleRate": "22050",
            },
            {
                "itag": 251,
                # ciphered: no url -> must never be handed out
                "signatureCipher": "s=abc&url=https%3A%2F%2Fexample.com",
                "mimeType": 'audio/webm; codecs="opus"',
                "bitrate": 133000,
            },
            {
                "itag": 137,
                "url": "https://r1.googlevideo.com/videoplayback?exp=1&sig=C",
                "mimeType": 'video/mp4; codecs="avc1.640028"',
                "bitrate": 2000000,
            },
        ],
    },
}


class FakeClient(innertube.InnerTubeClient):
    """InnerTube client whose HTTP layer is replaced by canned payloads."""

    def __init__(self, player=None, search_tracks=None):
        super().__init__()
        self._player = player if player is not None else PLAYER_RESPONSE
        self._search_tracks = search_tracks or []
        self.calls = []

    def _player_data(self, video_id, client="IOS"):
        self.calls.append(("player", client, video_id))
        playability = self._player.get("playabilityStatus") or {}
        status = playability.get("status")
        if status and status != "OK":
            reason = playability.get("reason") or status
            raise innertube.InnerTubeError(reason, kind=self._classify(reason))
        return self._player

    def _search_from_results_page(self, query, limit):
        return list(self._search_tracks)

    def _search_from_api(self, query, limit):
        return list(self._search_tracks)


# --------------------------------------------------------------------------
# 1. response parsing
# --------------------------------------------------------------------------

def test_extract_visitor_data():
    page = 'ytcfg.set({"VISITOR_DATA":"CgtNQk5rV2Vy"});'
    assert innertube.InnerTubeClient._extract_visitor_data(page) == "CgtNQk5rV2Vy"


def test_extract_ytcfg():
    page = 'ytcfg.set({"INNERTUBE_CLIENT_VERSION":"2.20261113.00.00","INNERTUBE_API_KEY":"k"});'
    cfg = innertube.InnerTubeClient._extract_ytcfg(page)
    assert cfg["INNERTUBE_CLIENT_VERSION"] == "2.20261113.00.00"


def test_extract_js_json_string_handles_escaped_payload():
    payload = {"contents": {"a": "it's fine \\ escaped"}}
    # the real page carries a JS string literal: var ytInitialData = '{...}'
    page = "var ytInitialData = " + repr(json.dumps(payload))
    decoded = innertube.InnerTubeClient._extract_js_json_string(page, "var ytInitialData")
    assert decoded == payload


# --------------------------------------------------------------------------
# 2. format selection
# --------------------------------------------------------------------------

def test_select_formats_keeps_only_playable_audio():
    formats = innertube.InnerTubeClient._select_formats(PLAYER_RESPONSE["streamingData"])
    # 251 is ciphered (no url) and 137 is video -> both excluded
    assert set(formats) == {"140", "139"}


def test_pick_format_prefers_highest_aac():
    formats = innertube.InnerTubeClient._select_formats(PLAYER_RESPONSE["streamingData"])
    assert innertube.InnerTubeClient._pick_format(formats)["itag"] == 140


# --------------------------------------------------------------------------
# 3./4. contracts
# --------------------------------------------------------------------------

def test_resolve_stream_keeps_ytm_client_contract():
    stream = FakeClient().resolve_stream("abc123")
    assert stream["video_id"] == "abc123"
    assert stream["expires_in_seconds"] == 21600
    assert stream["duration"] == 212
    assert stream["title"] == "Test Track"
    best = stream["audio_formats"][0]
    for key in ("itag", "url", "mime_type", "bitrate", "content_length",
                "audio_sample_rate", "format_note"):
        assert key in best
    # the backend's convention is 'm4a'/'webm', NOT a full MIME type
    assert best["mime_type"] == "m4a"
    assert {f["mime_type"] for f in stream["audio_formats"]} == {"m4a"}


def test_resolve_audio_keeps_extractor_contract():
    info = FakeClient().resolve_audio("abc123")
    for key in ("url", "ext", "abr", "codec", "filesize", "format_id", "duration"):
        assert key in info
    assert info["ext"] == "m4a"
    assert info["url"].startswith("https://")


def test_resolve_audio_raises_when_no_audio_format():
    client = FakeClient(player={"playabilityStatus": {"status": "OK"},
                                "streamingData": {"adaptiveFormats": []}})
    with pytest.raises(innertube.InnerTubeError):
        client.resolve_audio("abc123")


def test_playability_error_is_classified():
    client = FakeClient(player={"playabilityStatus": {
        "status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"}})
    with pytest.raises(innertube.InnerTubeError) as excinfo:
        client.resolve_audio("abc123")
    assert excinfo.value.kind == "needs_login"


# --------------------------------------------------------------------------
# 5. search -> TrackResponse
# --------------------------------------------------------------------------

def test_search_maps_onto_track_response_contract():
    from server import TrackResponse, _innertube_track_to_response

    track = {
        "video_id": "dQw4w9WgXcQ",
        "title": "Never Gonna Give You Up",
        "artist": "Rick Astley",
        "duration": "3:32",
        "thumbnails": [
            {"url": "https://i.ytimg.com/vi/x/default.jpg", "width": 120, "height": 90},
            {"url": "https://i.ytimg.com/vi/x/hq.jpg", "width": 480, "height": 360},
        ],
    }
    mapped = _innertube_track_to_response(track)
    validated = TrackResponse(**mapped).model_dump()
    assert validated["videoId"] == "dQw4w9WgXcQ"
    assert validated["title"] == "Never Gonna Give You Up"
    assert validated["artists"] == ["Rick Astley"]
    assert validated["durationSeconds"] == 212
    assert validated["thumbnailSmall"]["width"] == 120
    assert validated["thumbnailLarge"]["width"] == 480


def test_parse_duration_to_seconds():
    from server import _parse_duration_to_seconds
    assert _parse_duration_to_seconds("3:32") == 212
    assert _parse_duration_to_seconds("1:02:03") == 3723
    assert _parse_duration_to_seconds("") == 0
    assert _parse_duration_to_seconds("nonsense") == 0


# --------------------------------------------------------------------------
# 6. chunked CDN download
# --------------------------------------------------------------------------

class FakeResponse:
    def __init__(self, status_code, content=b"", headers=None):
        self.status_code = status_code
        self.content = content
        self.headers = headers or {}

    def iter_content(self, size=65536):
        data = self.content
        for start in range(0, len(data), size):
            yield data[start:start + size]


class FakeSession:
    """Models YouTube's CDN.

    capped=False  -> an unrestricted URL: an open-ended Range returns the
                     whole body in one response (what yt-dlp's URL does).
    capped=True   -> a preview-capped URL: an open-ended Range and a plain
                     GET are both refused, and only the first megabyte is
                     served before the CDN answers 403.
    """

    def __init__(self, total=4096, fail_at=None, capped=False):
        self.total = total
        self.fail_at = fail_at
        self.capped = capped
        self.requests = []

    def get(self, url, headers=None, timeout=None, stream=False):
        headers = headers or {}
        rng = headers.get("Range")
        self.requests.append(rng)
        if rng is None:
            if self.capped:
                return FakeResponse(403)
            return FakeResponse(200, b"a" * self.total)
        if rng == "bytes=0-":
            if self.capped:
                return FakeResponse(403)
            return FakeResponse(206, b"a" * self.total,
                                {"Content-Range": f"bytes 0-{self.total - 1}/{self.total}"})
        if rng == "bytes=0-0":
            return FakeResponse(206, b"x",
                                {"Content-Range": f"bytes 0-0/{self.total}"})
        start = int(rng.split("=")[1].split("-")[0])
        if self.fail_at is not None and start >= self.fail_at:
            return FakeResponse(403)
        end = min(start + innertube.CDN_CHUNK_SIZE - 1, self.total - 1)
        return FakeResponse(206, b"a" * (end - start + 1))


def test_download_audio_prefers_the_open_ended_range(tmp_path):
    """One request, whole file - measured 0.24s for 5.8 MB on the homelab."""
    destination = tmp_path / "source.m4a"
    session = FakeSession(total=1024 * 1024 + 4096)
    written = innertube.InnerTubeClient.download_audio(
        "https://example.com/v", str(destination), session=session)
    assert written == 1024 * 1024 + 4096
    assert destination.stat().st_size == written
    # one request, and it is the open-ended range
    assert session.requests == ["bytes=0-"]


def test_download_audio_falls_back_when_the_open_ended_range_is_refused(tmp_path):
    """A preview-capped URL: open-ended range and plain GET are refused."""
    destination = tmp_path / "source.m4a"
    session = FakeSession(total=4 * 1024 * 1024, fail_at=1024 * 1024, capped=True)
    with pytest.raises(IOError):
        innertube.InnerTubeClient.download_audio(
            "https://example.com/v", str(destination), session=session)
    # it tried the open-ended range, then the plain GET, then the chunks
    assert session.requests[0] == "bytes=0-"
    assert None in session.requests


def test_download_audio_raises_when_the_cdn_caps_the_file(tmp_path):
    """The preview-capped case: 1 MB served, then 403 for everything else."""
    destination = tmp_path / "source.m4a"
    session = FakeSession(total=4 * 1024 * 1024, fail_at=1024 * 1024, capped=True)
    with pytest.raises(IOError):
        innertube.InnerTubeClient.download_audio(
            "https://example.com/v", str(destination), session=session)


# --------------------------------------------------------------------------
# 7. ytm_client fallback
# --------------------------------------------------------------------------

def test_get_stream_url_falls_back_to_ytdlp(monkeypatch):
    import ytm_client

    class Boom(innertube.InnerTubeClient):
        def resolve_stream(self, video_id):
            raise innertube.InnerTubeError("blocked", kind="blocked")

    monkeypatch.setattr(innertube, "get_client", lambda: Boom())

    client = ytm_client.YTMusicClient.__new__(ytm_client.YTMusicClient)
    called = {}

    def fake_ytdlp(video_id):
        called["id"] = video_id
        return {"video_id": video_id, "audio_formats": []}

    monkeypatch.setattr(client, "_get_stream_url_ytdlp", fake_ytdlp)
    result = client.get_stream_url("abc123")
    assert called["id"] == "abc123"
    assert result["video_id"] == "abc123"


# --------------------------------------------------------------------------
# 8. /search prefers InnerTube
# --------------------------------------------------------------------------

def _fake_request(app):
    """A minimal Starlette request - the slowapi limiter needs request.app."""
    from starlette.requests import Request
    scope = {
        "type": "http",
        "method": "POST",
        "path": "/search",
        "headers": [],
        "query_string": b"",
        "app": app,
        "client": ("127.0.0.1", 5555),
        "server": ("testserver", 80),
        "scheme": "http",
    }
    return Request(scope)


def test_search_endpoint_prefers_innertube(monkeypatch):
    # NOTE: the backend's TestClient is unusable in this venv (starlette
    # 0.35 + httpx 0.28 -> "Client.__init__() got an unexpected keyword
    # argument 'app'"), so the handler coroutine is driven directly.
    import asyncio
    import server as server_module

    class StubClient:
        def __init__(self):
            self.calls = []

        def search(self, query, limit):
            self.calls.append((query, limit))
            return [{
                "video_id": "vid1",
                "title": "Stub Track",
                "artist": "Stub Artist",
                "duration": "3:00",
                "thumbnails": [{"url": "https://i.ytimg.com/x.jpg", "width": 480, "height": 360}],
            }]

    stub = StubClient()
    monkeypatch.setattr(server_module.innertube, "get_client", lambda: stub)
    monkeypatch.setattr(server_module, "search_cache", _NullCache())

    body = asyncio.run(server_module.search(
        server_module.SearchQuery(query="rick astley", limit=5),
        _fake_request(server_module.app),
        {"user_id": "u1"},
    ))
    assert body[0]["videoId"] == "vid1"
    assert body[0]["title"] == "Stub Track"
    assert body[0]["artists"] == ["Stub Artist"]
    assert body[0]["durationSeconds"] == 180
    assert stub.calls == [("rick astley", 5)]


def test_search_endpoint_falls_back_to_youtube_music(monkeypatch):
    import asyncio
    import server as server_module

    class EmptyInnerTube:
        def search(self, query, limit):
            return []

    class StubMusicClient:
        def __init__(self):
            self.calls = []

        def search_tracks(self, query, limit):
            self.calls.append((query, limit))
            # this is the shape YTMusicClient.search_tracks() returns
            return [{
                "videoId": "ymc1",
                "title": "Music API Track",
                "artists": ["Music API Artist"],
                "album": "Album",
                "durationSeconds": 200,
                "thumbnails": [{"url": "https://i.ytimg.com/y.jpg", "width": 480, "height": 360}],
                "thumbnailSmall": {"url": "https://i.ytimg.com/y.jpg", "width": 120, "height": 90},
                "thumbnailLarge": {"url": "https://i.ytimg.com/y.jpg", "width": 480, "height": 360},
                "isExplicit": False,
                "videoType": "MUSIC_VIDEO_TYPE_ATV",
            }]

    music = StubMusicClient()
    monkeypatch.setattr(server_module.innertube, "get_client", lambda: EmptyInnerTube())
    monkeypatch.setattr(server_module, "search_cache", _NullCache())
    monkeypatch.setattr(server_module, "get_client", lambda: music)

    body = asyncio.run(server_module.search(
        server_module.SearchQuery(query="fallback", limit=3),
        _fake_request(server_module.app),
        {"user_id": "u1"},
    ))
    assert body[0]["videoId"] == "ymc1"
    assert body[0]["title"] == "Music API Track"
    assert music.calls == [("fallback", 3)]


# --------------------------------------------------------------------------
# 9. transcode pipeline: remux instead of re-encode
# --------------------------------------------------------------------------

def test_get_media_url_prefers_aac_and_ignores_innertube(monkeypatch):
    """The media URL must come from yt-dlp.

    InnerTube's iOS URLs are preview-capped by YouTube's CDN (1 MB, then
    403), so the bytes cannot come from them. AAC m4a is preferred over
    webm/Opus because the transcode can then remux instead of re-encode.
    """
    import ytm_client

    client = ytm_client.YTMusicClient.__new__(ytm_client.YTMusicClient)
    client._media_url_cache = {}

    monkeypatch.setattr(client, "_get_stream_url_ytdlp", lambda video_id: {
        "video_id": video_id,
        "audio_formats": [
            {"itag": "251", "url": "https://cdn/opus", "mime_type": "webm",
             "bitrate": 133000},
            {"itag": "140", "url": "https://cdn/aac", "mime_type": "m4a",
             "bitrate": 129000},
        ],
    })
    assert client.get_media_url("abc123") == "https://cdn/aac"

    # the second call is served from the cache, not from yt-dlp again
    monkeypatch.setattr(client, "_get_stream_url_ytdlp", lambda video_id: None)
    assert client.get_media_url("abc123") == "https://cdn/aac"


def test_get_media_url_returns_none_when_nothing_resolves(monkeypatch):
    import ytm_client

    client = ytm_client.YTMusicClient.__new__(ytm_client.YTMusicClient)
    client._media_url_cache = {}
    monkeypatch.setattr(client, "_get_stream_url_ytdlp", lambda video_id: None)
    assert client.get_media_url("abc123") is None


def test_resolve_media_uses_the_visionos_client_and_prefers_aac(monkeypatch):
    """The media URL must come from the visionOS client.

    Its URLs are pre-signed (no decipher) and, unlike the iOS client's,
    NOT preview-capped - so they can carry a whole track.
    """
    client = FakeClient()
    seen = {}

    def fake_player_data(video_id, client="IOS"):
        seen["client"] = client
        return PLAYER_RESPONSE

    monkeypatch.setattr(client, "_player_data", fake_player_data)
    media = client.resolve_media("abc123")
    assert seen["client"] == "VISIONOS"
    assert media["url"].startswith("https://")
    assert media["mime_type"] == "m4a"
    assert media["itag"] == 140
    assert media["_resolver"] == "innertube_visionos"


def test_resolve_media_falls_back_to_another_audio_format(monkeypatch):
    client = FakeClient()
    payload = {
        "playabilityStatus": {"status": "OK"},
        "videoDetails": {"lengthSeconds": "100"},
        "streamingData": {"adaptiveFormats": [
            {"itag": 251, "url": "https://cdn/opus", "mimeType": 'audio/webm; codecs="opus"',
             "bitrate": 133000},
        ]},
    }
    monkeypatch.setattr(client, "_player_data", lambda video_id, client="IOS": payload)
    media = client.resolve_media("abc123")
    assert media["itag"] == 251
    assert media["mime_type"] == "webm"


def test_thumbnail_urls_are_pointed_at_our_proxy():
    from server import _innertube_track_to_response, _proxy_thumbnails

    track = {
        "video_id": "FGBhQbmPwH8",
        "title": "One More Time",
        "artist": "Daft Punk",
        "duration": "5:22",
        "thumbnails": [
            {"url": "https://i.ytimg.com/vi/FGBhQbmPwH8/default.jpg", "width": 120, "height": 90},
            {"url": "https://i.ytimg.com/vi/FGBhQbmPwH8/hqdefault.jpg", "width": 480, "height": 360},
        ],
    }
    mapped = _innertube_track_to_response(track, "http://batuniverse:8181")
    urls = [t["url"] for t in mapped["thumbnails"]]
    assert all(u.startswith("http://batuniverse:8181/thumb/") for u in urls)
    assert "/thumb/FGBhQbmPwH8.jpg" in urls[0]
    # the small thumbnail is still the small one
    assert mapped["thumbnailSmall"]["width"] == 120
    assert mapped["thumbnailLarge"]["width"] == 480


def test_proxy_thumbnails_leaves_foreign_urls_alone():
    from server import _proxy_thumbnails

    out = _proxy_thumbnails([{"url": "https://example.com/art.jpg", "width": 100}], "http://x")
    assert out == []


def test_thumbnail_endpoint_caches_the_image(tmp_path, monkeypatch):
    import asyncio
    import server as server_module

    monkeypatch.setattr(server_module, "THUMB_CACHE_DIR", tmp_path)

    class FakeResp:
        status_code = 200
        content = b"x" * 500

    calls = []

    def fake_get(url, headers=None, timeout=None):
        calls.append(url)
        return FakeResp()

    monkeypatch.setattr(server_module._requests, "get", fake_get)

    async def scenario():
        req = _fake_request(server_module.app)
        first = await server_module.thumbnail("FGBhQbmPwH8", req, s="hqdefault")
        second = await server_module.thumbnail("FGBhQbmPwH8", req, s="hqdefault")
        return first, second

    first, second = asyncio.run(scenario())
    assert first.media_type == "image/jpeg"
    assert len(first.body) == 500
    assert second.body == first.body
    # the second call was served from disk
    assert len(calls) == 1


def test_fast_endpoint_does_not_block_on_the_itag18_probe(monkeypatch):
    """/fast must answer immediately.

    The itag-18 probe costs a yt-dlp subprocess (~3s) and the production
    yt-dlp does not offer itag 18 for music videos, so it runs in the
    background and the play goes straight to the transcoded path.
    """
    import asyncio
    from fastapi import BackgroundTasks
    import server as server_module

    monkeypatch.setattr(server_module, "_format18_probe_disabled", False)
    monkeypatch.setattr(server_module, "current_user_from_request",
                        lambda header: {"user_id": "u1"})

    spawned = []

    async def fail_if_spawned(*args, **kwargs):
        spawned.append(args)
        raise AssertionError("the /fast endpoint must not spawn yt-dlp inline")

    monkeypatch.setattr(server_module.asyncio, "create_subprocess_exec", fail_if_spawned)

    async def scenario():
        req = _fake_request(server_module.app)
        tasks = BackgroundTasks()
        response = await server_module.fast_stream("vid123", req, tasks)
        return response, tasks

    response, tasks = asyncio.run(scenario())
    assert response.status_code == 302
    assert "/audio/vid123.m4a" in response.headers["location"]
    assert spawned == []
    # the probe was scheduled as a background task instead
    assert len(tasks.tasks) == 1


def test_format18_probe_switches_itself_off(monkeypatch):
    """yt-dlp 2026.08.19 has no itag 18 for music videos.

    After a few consecutive "not available" answers the probe must stop
    costing a ~2.3s subprocess per cold play - and a single success has to
    bring it back (a yt-dlp downgrade restores itag 18).
    """
    import server as server_module

    monkeypatch.setattr(server_module, "_format18_misses", 0)
    monkeypatch.setattr(server_module, "_format18_probe_disabled", False)

    for _ in range(server_module._FORMAT18_MISS_LIMIT - 1):
        server_module._format18_record_probe(False, "Requested format is not available")
        assert server_module._format18_probe_disabled is False

    server_module._format18_record_probe(False, "Requested format is not available")
    assert server_module._format18_probe_disabled is True

    # a transient failure must not count as a verdict
    server_module._format18_record_probe(False, "HTTP Error 429: Too Many Requests")
    assert server_module._format18_probe_disabled is True

    # one success re-enables the probe
    server_module._format18_record_probe(True)
    assert server_module._format18_probe_disabled is False


def test_transcode_pipeline_remuxes_the_downloaded_audio(tmp_path, monkeypatch):
    """The InnerTube source is already AAC - it must be remuxed, not re-encoded.

    ffmpeg -c copy +faststart also moves the moov atom to the front, which
    is what AVPlayer needs before it can start playing a regular MP4.
    """
    import asyncio
    import shutil
    import subprocess

    from runtime_config import FFMPEG_BIN

    if not shutil.which(FFMPEG_BIN):
        pytest.skip("ffmpeg not available")

    import server as server_module

    # a source that looks like the InnerTube one: AAC in a fragmented MP4
    source = tmp_path / "source.m4a"
    subprocess.run(
        [FFMPEG_BIN, "-y", "-loglevel", "error",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
         "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-ar", "48000",
         "-movflags", "+frag_keyframe+empty_moov", "-f", "mp4", str(source)],
        check=True,
    )

    def fake_download(url, destination, session=None):
        shutil.copyfile(source, destination)
        return destination

    monkeypatch.setattr(server_module.innertube, "download_audio", fake_download)

    cache_path = tmp_path / "cached.m4a"
    asyncio.run(server_module._do_transcode_pipeline(
        "vid123", "https://example.com/videoplayback", cache_path))

    assert cache_path.exists()
    assert cache_path.stat().st_size > 1000
    data = cache_path.read_bytes()
    # moov (index) before mdat (payload) -> AVPlayer can start immediately
    assert 0 < data.find(b"moov") < data.find(b"mdat")
    # the temporary source file is cleaned up
    assert not (tmp_path / ".vid123.source").exists()


class _NullCache:
    def get(self, key):
        return None

    def set(self, key, value):
        return None
