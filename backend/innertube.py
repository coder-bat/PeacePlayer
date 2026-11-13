"""
InnerTube audio resolution and search.

Direct YouTube InnerTube access, modelled on how the Musi app resolves streams:
no yt-dlp extraction, no signature decipher, no `n` transform. Two calls:

  1. GET  https://m.youtube.com/watch?v=<id>       (iPhone UA) -> ytcfg + visitorData
  2. POST https://www.youtube.com/youtubei/v1/player?key=<key>
        context.client = {hl, clientName: IOS, clientVersion}
        contentCheckOk / racyCheckOk = true, videoId
        header: X-Goog-Visitor-Id

The IOS client answers with *pre-signed* adaptive audio URLs (itag 139/140 AAC
m4a) - no signatureCipher, so nothing has to be deciphered and the URL is
directly playable by AVPlayer.

Search uses the same client against the InnerTube `search` endpoint, with a
mobile results-page parse as the cheaper primary path.

What this client can NOT do (measured 2026-11-14, so it is not re-tried
blindly later): the iOS client never returns a progressive video+audio
format. Its player response has no "formats" array - only adaptive
video-only (itag 137/136/135) and audio-only (itag 140/139) streams.
WEB / MWEB / TVHTML5 answer "The page needs to be reloaded"
(UNPLAYABLE) and ANDROID_VR answers LOGIN_REQUIRED, so IOS is the only
usable InnerTube client. The progressive itag 18 the iOS app plays comes
from yt-dlp's web client instead (see backend/server.py, /fast).

Measured 2026-11-13 (this repo, live YouTube):
    watch page 0.21-1.0 s  +  player POST 0.41 s   -> ~0.6-1.4 s to audio URL
    (the previous yt-dlp path cost 1.74-2.38 s and could return zero audio formats)
"""

import ast
import json
import logging
import os
import re
import time
from typing import Any, Dict, List, Optional, Tuple

import requests

logger = logging.getLogger(__name__)

INNERTUBE_API_KEY = os.environ.get(
    "INNERTUBE_API_KEY", "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
)
INNERTUBE_CLIENT_VERSION = os.environ.get("INNERTUBE_CLIENT_VERSION", "20.10.4")
PLAYER_URL = "https://www.youtube.com/youtubei/v1/player?key=" + INNERTUBE_API_KEY
SEARCH_URL = "https://www.youtube.com/youtubei/v1/search?key=" + INNERTUBE_API_KEY
WATCH_URL = "https://m.youtube.com/watch?v={video_id}"
RESULTS_URL = "https://m.youtube.com/results?search_query={query}"

IOS_USER_AGENT = os.environ.get(
    "INNERTUBE_USER_AGENT",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 12_2 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Mobile/15E148 Safari/604.1",
)

# Highest preference first.
#  140/139 -> AAC m4a, pre-signed (what the IOS client returns)
#  251/250/249 -> opus, only used if the AAC ladder is missing
PREFERRED_ITAGS = ("140", "139", "251", "250", "249")

# YouTube's CDN rejects Range requests larger than ~1 MB with HTTP 403
# (verified 2026-11-13: bytes=0-1048575 -> 206, bytes=0-5242879 -> 403).
# Measured again 2026-11-14: from a datacenter egress IP the CDN serves
# only the first 1 MB of a file at all, and a plain GET without a Range
# header is refused outright. 512 KB keeps every chunk request inside the
# window that does work.
CDN_CHUNK_SIZE = 512 * 1024

# AVFoundation asks for the *whole* asset in a single Range request, which
# YouTube's CDN 403s. That is why the backend keeps serving a local
# transcoded file instead of redirecting AVPlayer straight at the CDN.
DOWNLOAD_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


class InnerTubeError(RuntimeError):
    """YouTube refused to hand over a playable audio stream."""

    def __init__(self, reason: str, kind: str = "blocked"):
        super().__init__(reason)
        self.reason = reason
        self.kind = kind


class InnerTubeClient:
    """Resolves YouTube audio URLs and search results through InnerTube."""

    def __init__(
        self,
        client_version: str = INNERTUBE_CLIENT_VERSION,
        hl: str = "en",
        timeout: float = 15.0,
        session: Optional[requests.Session] = None,
        cookies: Optional[Dict[str, str]] = None,
    ):
        self.client_version = client_version
        self.hl = hl
        self.timeout = timeout
        self.session = session or requests.Session()
        if cookies:
            self.session.cookies.update(cookies)
        self._visitor_data: Optional[str] = None
        self._api_key: str = INNERTUBE_API_KEY
        # Short-lived cache of raw player responses so a single cold play
        # (which asks "give me a progressive URL" and then "give me an
        # audio URL") does not POST to InnerTube twice.
        self._player_cache: Dict[str, Tuple[float, Dict[str, Any]]] = {}
        self._player_cache_ttl = 120.0

    # ------------------------------------------------------------------ #
    # helpers
    # ------------------------------------------------------------------ #
    def _headers(self, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        headers = {
            "User-Agent": IOS_USER_AGENT,
            "Accept-Language": f"{self.hl},en;q=0.9",
        }
        if extra:
            headers.update(extra)
        return headers

    @staticmethod
    def _extract_visitor_data(text: str) -> Optional[str]:
        for pattern in (r'"visitorData":"([^"]+)"', r'"VISITOR_DATA":"([^"]+)"'):
            match = re.search(pattern, text)
            if match:
                return match.group(1)
        return None

    @staticmethod
    def _extract_ytcfg(text: str) -> Optional[Dict[str, Any]]:
        match = re.search(r"ytcfg\.set\((\{[\s\S]*?\})\);", text)
        if not match:
            return None
        try:
            return json.loads(match.group(1))
        except (ValueError, TypeError):
            return None

    @staticmethod
    def _extract_js_json_string(text: str, marker: str) -> Optional[Any]:
        """Pull a JS string literal (e.g. `var ytInitialData = '{...}'`) and decode it."""
        index = text.find(marker)
        if index < 0:
            return None
        quote = text.find("'", index)
        if quote < 0:
            return None
        cursor = quote + 1
        escaped = False
        while cursor < len(text):
            char = text[cursor]
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == "'":
                break
            cursor += 1
        try:
            return json.loads(ast.literal_eval(text[quote:cursor + 1]))
        except (ValueError, SyntaxError):
            return None

    def _fetch_page(self, url: str) -> str:
        response = self.session.get(url, headers=self._headers(), timeout=self.timeout)
        response.raise_for_status()
        return response.text

    def _player_payload(self, video_id: str) -> Dict[str, Any]:
        return {
            "context": {
                "client": {
                    "hl": self.hl,
                    "clientName": "IOS",
                    "clientVersion": self.client_version,
                },
                "user": {"lockedSafetyMode": False},
                "request": {
                    "useSsl": True,
                    "internalExperimentFlags": [],
                    "consistencyTokenJars": [],
                },
            },
            "contentCheckOk": True,
            "racyCheckOk": True,
            "videoId": video_id,
        }

    # ------------------------------------------------------------------ #
    # playback
    # ------------------------------------------------------------------ #
    def _visitor_for_video(self, video_id: str) -> Optional[str]:
        """visitorData is session-scoped; the watch page always carries it."""
        if self._visitor_data:
            return self._visitor_data
        page = self._fetch_page(WATCH_URL.format(video_id=video_id))
        visitor = self._extract_visitor_data(page)
        if visitor:
            self._visitor_data = visitor
        return visitor

    def _player_response(self, video_id: str, visitor_data: Optional[str]) -> Dict[str, Any]:
        headers = self._headers({
            "Content-Type": "application/json",
            "Origin": "https://www.youtube.com",
        })
        if visitor_data:
            headers["X-Goog-Visitor-Id"] = visitor_data
        response = self.session.post(
            PLAYER_URL,
            data=json.dumps(self._player_payload(video_id)),
            headers=headers,
            timeout=self.timeout,
        )
        response.raise_for_status()
        return response.json()

    @staticmethod
    def _select_formats(streaming_data: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
        """Keep audio-only formats that are directly playable (no signatureCipher)."""
        formats: Dict[str, Dict[str, Any]] = {}
        for fmt in streaming_data.get("adaptiveFormats") or []:
            itag = str(fmt.get("itag", ""))
            mime = fmt.get("mimeType") or ""
            if not mime.startswith("audio"):
                continue
            if not fmt.get("url"):
                # ciphered formats would need yt-dlp's decipher - never hand those out
                continue
            formats[itag] = fmt
        return formats

    @staticmethod
    def _pick_format(formats: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        for itag in PREFERRED_ITAGS:
            if itag in formats:
                return formats[itag]
        if formats:
            return max(formats.values(), key=lambda item: item.get("bitrate") or 0)
        return None

    def resolve_audio(self, video_id: str) -> Dict[str, Any]:
        """Resolve a video id to a directly playable audio URL.

        Returns the same shape as AudioExtractor.get_audio_info() so the rest of
        the backend (and the iOS client) needs no changes.
        """
        started = time.time()
        data = self._player_data(video_id)
        total_seconds = time.time() - started

        streaming = data.get("streamingData") or {}
        formats = self._select_formats(streaming)
        best = self._pick_format(formats)
        if not best:
            raise InnerTubeError(
                "no directly playable audio format in streamingData",
                kind="no_formats",
            )

        details = data.get("videoDetails") or {}
        mime = best.get("mimeType") or ""
        return {
            "url": best.get("url"),
            "ext": "m4a" if "mp4" in mime else "webm",
            "abr": round((best.get("bitrate") or 0) / 1000),
            "codec": mime.split("codecs=")[-1].strip('"') or None,
            "filesize": 0,
            "format_id": best.get("itag"),
            "duration": int(details.get("lengthSeconds") or 0),
            # diagnostics - not consumed by the client, useful in logs
            "_resolver": "innertube_ios",
            "_pre_signed": "signatureCipher" not in best,
            "_hls_manifest": streaming.get("hlsManifestUrl"),
            "_t_watch": round(total_seconds, 3),
            "_t_total": round(total_seconds, 3),
            "_title": details.get("title"),
        }

    def _player_data(self, video_id: str) -> Dict[str, Any]:
        """Raw InnerTube player response, cached briefly per video id."""
        cached = self._player_cache.get(video_id)
        if cached and (time.time() - cached[0]) < self._player_cache_ttl:
            return cached[1]

        page = self._fetch_page(WATCH_URL.format(video_id=video_id))
        visitor = self._extract_visitor_data(page) or self._visitor_data
        if visitor:
            self._visitor_data = visitor

        data = self._player_response(video_id, visitor)

        playability = data.get("playabilityStatus") or {}
        status = playability.get("status")
        if status and status != "OK":
            reason = playability.get("reason") or status
            raise InnerTubeError(reason, kind=self._classify(reason))

        self._player_cache[video_id] = (time.time(), data)
        return data

    def resolve_stream(self, video_id: str) -> Dict[str, Any]:
        """Resolve a video id into the shape ytm_client.get_stream_url() returns.

        Keeping the contract identical means the rest of the backend (and the
        iOS client) needs no changes at all.
        """
        started = time.time()
        data = self._player_data(video_id)
        streaming = data.get("streamingData") or {}
        formats = self._select_formats(streaming)
        best = self._pick_format(formats)
        if not best:
            raise InnerTubeError(
                "no directly playable audio format in streamingData",
                kind="no_formats",
            )

        details = data.get("videoDetails") or {}
        mime = best.get("mimeType") or ""
        audio_formats = []
        for itag, fmt in formats.items():
            fmt_mime = fmt.get("mimeType") or ""
            # The backend's convention is 'm4a'/'webm' (NOT a full MIME type)
            # - server.py branches on the literal 'webm'.
            extension = "m4a" if "mp4" in fmt_mime else "webm"
            audio_formats.append({
                "itag": itag,
                "url": fmt.get("url"),
                "mime_type": extension,
                "bitrate": int(fmt.get("bitrate") or 0),
                "content_length": int(fmt.get("contentLength") or 0),
                "audio_sample_rate": int(fmt.get("audioSampleRate") or 0),
                "format_note": fmt_mime,
            })
        audio_formats.sort(key=lambda item: item["bitrate"], reverse=True)

        return {
            "video_id": video_id,
            "audio_formats": audio_formats,
            "expires_in_seconds": int(streaming.get("expiresInSeconds") or 21600),
            "title": details.get("title") or "",
            "duration": int(details.get("lengthSeconds") or 0),
            # diagnostics
            "_resolver": "innertube_ios",
            "_itag": best.get("itag"),
            "_pre_signed": "signatureCipher" not in best,
            "_t_total": round(time.time() - started, 3),
        }

    @staticmethod
    def download_audio(url: str, destination: str, session: Optional[requests.Session] = None) -> int:
        """Download a YouTube CDN URL in Range chunks.

        Measured 2026-11-14 (this machine, egress 144.6.2.185): YouTube's
        CDN serves at most the FIRST 1 MB of a file to this IP, no matter
        how the request is shaped -

            bytes=0-1048575     -> 206 (1 MB)
            bytes=524288-1048575-> 206
            bytes=1048576-...   -> 403
            plain GET (no Range) -> 403

        yt-dlp's own downloader hits the same 403, so this is a property of
        the egress IP (datacenter range), not of InnerTube or of the URL.
        From a residential IP the same chunked download works.

        Chunk size is therefore kept at 512 KB and every chunk is checked
        for 206: the caller (server._do_transcode_pipeline) falls back to
        the yt-dlp pipe when this raises, so a capped IP degrades to the
        old behaviour instead of hanging.
        """
        http = session or requests.Session()
        headers = {"User-Agent": DOWNLOAD_USER_AGENT}

        probe = http.get(url, headers={**headers, "Range": "bytes=0-0"}, timeout=20)
        total = 0
        content_range = probe.headers.get("Content-Range", "")
        match = re.match(r"bytes (\d+)-(\d+)/(\d+)", content_range)
        if match:
            total = int(match.group(3))
        elif probe.headers.get("Content-Length"):
            total = int(probe.headers["Content-Length"])

        written = 0
        with open(destination, "wb") as handle:
            position = 0
            while total and position < total:
                end = min(position + CDN_CHUNK_SIZE, total) - 1
                chunk = http.get(
                    url,
                    headers={**headers, "Range": f"bytes={position}-{end}"},
                    timeout=30,
                )
                if chunk.status_code != 206:
                    raise IOError(
                        f"CDN range {position}-{end} returned {chunk.status_code}"
                    )
                handle.write(chunk.content)
                written += len(chunk.content)
                position = end + 1
        if written < 1000:
            raise IOError(f"chunked download produced only {written} bytes")
        return written

    @staticmethod
    def _classify(reason: str) -> str:
        low = (reason or "").lower()
        if "sign in" in low or "bot" in low or "confirm" in low:
            return "needs_login"
        if "kids" in low or "age" in low:
            return "age_restricted"
        if "copyright" in low:
            return "copyright"
        if "unavailable" in low or "private" in low or "removed" in low:
            return "unavailable"
        return "blocked"

    # ------------------------------------------------------------------ #
    # search
    # ------------------------------------------------------------------ #
    def search(self, query: str, limit: int = 20) -> List[Dict[str, Any]]:
        """Search YouTube the way Musi does - same InnerTube client, same shapes.

        Primary path parses the mobile results page (one ~550 KB request);
        the InnerTube JSON endpoint is the fallback (bigger payload, same client).
        """
        results = self._search_from_results_page(query, limit)
        if results:
            return results[:limit]
        return self._search_from_api(query, limit)[:limit]

    def _search_from_results_page(self, query: str, limit: int) -> List[Dict[str, Any]]:
        try:
            page = self._fetch_page(RESULTS_URL.format(query=requests.utils.quote(query)))
        except requests.RequestException as exc:
            logger.warning("results page fetch failed for %r: %s", query, exc)
            return []

        visitor = self._extract_visitor_data(page)
        if visitor:
            self._visitor_data = visitor

        data = self._extract_js_json_string(page, "var ytInitialData")
        if not data:
            return []

        tracks: List[Dict[str, Any]] = []
        seen = set()

        def title_of(node: Dict[str, Any]) -> str:
            title = node.get("title")
            if isinstance(title, dict):
                if title.get("simpleText"):
                    return title["simpleText"]
                runs = title.get("runs") or []
                if runs:
                    return "".join(run.get("text", "") for run in runs)
            return ""

        def text_of(node: Optional[Dict[str, Any]]) -> str:
            if not isinstance(node, dict):
                return ""
            if node.get("simpleText"):
                return node["simpleText"]
            runs = node.get("runs") or []
            return "".join(run.get("text", "") for run in runs)

        def thumbnails_of(node: Any) -> List[Dict[str, Any]]:
            if not isinstance(node, dict):
                return []
            out = []
            for thumb in node.get("thumbnails") or []:
                if not isinstance(thumb, dict) or not thumb.get("url"):
                    continue
                out.append({
                    "url": thumb["url"],
                    "width": int(thumb.get("width") or 0),
                    "height": int(thumb.get("height") or 0),
                })
            return out

        def walk(node: Any) -> None:
            if isinstance(node, dict):
                # modern mobile search result
                renderer = node.get("videoWithContextRenderer")
                if renderer:
                    video_id = renderer.get("videoId")
                    if video_id and video_id not in seen:
                        seen.add(video_id)
                        tracks.append({
                            "video_id": video_id,
                            "title": title_of({"title": renderer.get("headline")}),
                            "artist": text_of(renderer.get("shortBylineText")),
                            "duration": text_of(renderer.get("lengthText")),
                            "views": text_of(renderer.get("shortViewCountText")),
                            "published": text_of(renderer.get("publishedTimeText")),
                            "thumbnails": thumbnails_of(renderer.get("thumbnail")),
                            "source": "innertube_page",
                        })

                # lockup view model (desktop-ish result shape)
                lockup = node.get("lockupViewModel")
                if lockup:
                    video_id = lockup.get("contentId")
                    metadata = (lockup.get("metadata") or {}).get("lockupMetadataViewModel") or {}
                    if video_id and video_id not in seen:
                        seen.add(video_id)
                        tracks.append({
                            "video_id": video_id,
                            "title": title_of(metadata.get("title")),
                            "artist": text_of(metadata.get("metadata")),
                            "duration": "",
                            "views": "",
                            "published": "",
                            "thumbnails": thumbnails_of((metadata.get("contentImage") or {})),
                            "source": "innertube_page",
                        })

                # classic video renderer
                classic = node.get("videoRenderer")
                if classic:
                    video_id = classic.get("videoId")
                    if video_id and video_id not in seen:
                        seen.add(video_id)
                        tracks.append({
                            "video_id": video_id,
                            "title": title_of(classic),
                            "artist": text_of(classic.get("ownerText") or classic.get("longBylineText")),
                            "duration": text_of(classic.get("lengthText")),
                            "views": text_of(classic.get("viewCountText")),
                            "published": text_of(classic.get("publishedTimeText")),
                            "thumbnails": thumbnails_of(classic.get("thumbnail")),
                            "source": "innertube_page",
                        })

                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)

        walk(data)
        return tracks

    def _search_from_api(self, query: str, limit: int) -> List[Dict[str, Any]]:
        payload = {
            "context": {
                "client": {
                    "hl": self.hl,
                    "clientName": "IOS",
                    "clientVersion": self.client_version,
                },
                "user": {"lockedSafetyMode": False},
            },
            "query": query,
        }
        headers = self._headers({
            "Content-Type": "application/json",
            "Origin": "https://www.youtube.com",
        })
        if self._visitor_data:
            headers["X-Goog-Visitor-Id"] = self._visitor_data
        try:
            response = self.session.post(
                SEARCH_URL, data=json.dumps(payload), headers=headers, timeout=self.timeout
            )
            response.raise_for_status()
            data = response.json()
        except (requests.RequestException, ValueError) as exc:
            logger.warning("innertube search failed for %r: %s", query, exc)
            return []

        tracks: List[Dict[str, Any]] = []
        seen = set()

        def text_of(node: Any) -> str:
            if not isinstance(node, dict):
                return ""
            if node.get("simpleText"):
                return node["simpleText"]
            runs = node.get("runs") or []
            return "".join(run.get("text", "") for run in runs)

        def thumbnails_of(node: Any) -> List[Dict[str, Any]]:
            if not isinstance(node, dict):
                return []
            out = []
            for thumb in node.get("thumbnails") or []:
                if not isinstance(thumb, dict) or not thumb.get("url"):
                    continue
                out.append({
                    "url": thumb["url"],
                    "width": int(thumb.get("width") or 0),
                    "height": int(thumb.get("height") or 0),
                })
            return out

        def walk(node: Any) -> None:
            if isinstance(node, dict):
                renderer = node.get("videoRenderer")
                if renderer:
                    video_id = renderer.get("videoId")
                    if video_id and video_id not in seen:
                        seen.add(video_id)
                        tracks.append({
                            "video_id": video_id,
                            "title": text_of(renderer.get("title")),
                            "artist": text_of(renderer.get("ownerText") or renderer.get("longBylineText")),
                            "duration": text_of(renderer.get("lengthText")),
                            "views": text_of(renderer.get("viewCountText")),
                            "published": text_of(renderer.get("publishedTimeText")),
                            "thumbnails": thumbnails_of(renderer.get("thumbnail")),
                            "source": "innertube_api",
                        })
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)

        walk(data)
        return tracks


_client: Optional[InnerTubeClient] = None


def get_client() -> InnerTubeClient:
    """Shared InnerTube client (keeps one connection pool + visitorData)."""
    global _client
    if _client is None:
        _client = InnerTubeClient()
    return _client


def reset_client() -> None:
    """Drop the cached client (used by tests and after a config change)."""
    global _client
    _client = None


def download_audio(url: str, destination: str) -> int:
    """Module-level wrapper around InnerTubeClient.download_audio."""
    return InnerTubeClient.download_audio(url, destination)
