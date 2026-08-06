"""
FastAPI Server
HTTP interface for iOS client to access extraction capabilities.
Works with or without authentication.
"""

from fastapi import FastAPI, HTTPException, BackgroundTasks, Request, Response, Query, Path as APIPath, Depends
from fastapi.responses import FileResponse, RedirectResponse, StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from pydantic import BaseModel, Field, ConfigDict
from pydantic.alias_generators import to_camel
from typing import List, Optional
import os
import re
import asyncio
import logging
import json
import time
import uuid
import glob as _glob
import datetime
import shlex
import requests as _requests
import xml.etree.ElementTree as ET
from pathlib import Path

import httpx

# S17 (CV-3): load backend/.env at import time so dev runs
# pick up PEACEPLAYER_JWT_SECRET (and other vars) from a file
# rather than requiring shell exports. In production the
# launchd plist sets the env directly and this becomes a
# no-op (the file doesn't exist on the production host).
from dotenv import load_dotenv
_env_path = Path(__file__).parent / ".env"
if _env_path.exists():
    load_dotenv(_env_path, override=False)

from ytm_client import YTMusicClient, get_client, reset_client
from extractor import AudioExtractor, get_extractor
from stream_cache import get_cache
from apple_auth import (
    verify_apple_identity_token,
    mint_session_jwt,
    current_user_from_request,
    get_or_create_user,
    touch_last_seen,
    load_sync_blob,
    save_sync_blob,
)

# --- Configuration from environment ---
STREAM_CONNECT_TIMEOUT = float(os.environ.get("STREAM_CONNECT_TIMEOUT", "5"))
# S15: 30s was too short for audio streams - a 35s CDN stall
# killed the whole song. Raise to 120s; the client will still
# see a fast failure because the bytes-per-second read
# threshold is what actually matters in practice. Override via
# the env var if you need a different ceiling.
STREAM_READ_TIMEOUT = float(os.environ.get("STREAM_READ_TIMEOUT", "120"))
THUMBNAIL_CONNECT_TIMEOUT = float(os.environ.get("THUMBNAIL_CONNECT_TIMEOUT", "3"))
THUMBNAIL_READ_TIMEOUT = float(os.environ.get("THUMBNAIL_READ_TIMEOUT", "10"))
HTTP_POOL_SIZE = int(os.environ.get("HTTP_POOL_SIZE", "10"))
HTTP_POOL_MAX = int(os.environ.get("HTTP_POOL_MAX", "20"))
YOUTUBE_COUNTRY = os.environ.get("YOUTUBE_COUNTRY", "US")
SEARCH_CACHE_TTL = int(os.environ.get("SEARCH_CACHE_TTL", "300"))
TRENDING_CACHE_TTL = int(os.environ.get("TRENDING_CACHE_TTL", "900"))
MAX_WAVEFORM_CACHE_MB = int(os.environ.get("MAX_WAVEFORM_CACHE_MB", "100"))
CACHE_TTL_HOURS = float(os.environ.get("CACHE_TTL_HOURS", "3.5"))

# S17-H / S17-PLAY (Fix 1, 2026-07-29): Use absolute paths for
# external binaries. The backend runs under launchd as a Background
# process, which IGNORES the EnvironmentVariables.PATH override in the
# plist — verified empirically (the running process PATH is just
# /usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin, missing both
# /Library/Frameworks/Python.framework/Versions/3.10/bin where yt-dlp
# lives, and /opt/homebrew/bin where ffmpeg + deno live). Using
# absolute paths is more robust than relying on PATH at all.
YTDLP_BIN = os.environ.get("YTDLP_BIN", "/Library/Frameworks/Python.framework/Versions/3.10/bin/yt-dlp")
FFMPEG_BIN = os.environ.get("FFMPEG_BIN", "/opt/homebrew/bin/ffmpeg")
DENO_BIN = os.environ.get("DENO_BIN", "/opt/homebrew/bin/deno")

# --- Structured JSON logging ---
class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_data = {
            "timestamp": datetime.datetime.utcnow().isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        if hasattr(record, 'request_id'):
            log_data["request_id"] = record.request_id
        if record.exc_info and record.exc_info[0]:
            log_data["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_data)

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger = logging.getLogger(__name__)
logger.handlers = [handler]
logger.setLevel(logging.INFO)
logger.propagate = False

# --- TTL Cache ---
class TTLCache:
    def __init__(self, ttl_seconds=300, max_size=100):
        self._cache = {}
        self._ttl = ttl_seconds
        self._max_size = max_size

    def get(self, key):
        if key in self._cache:
            value, timestamp = self._cache[key]
            if time.time() - timestamp < self._ttl:
                return value
            del self._cache[key]
        return None

    def set(self, key, value):
        if len(self._cache) >= self._max_size:
            oldest_key = min(self._cache, key=lambda k: self._cache[k][1])
            del self._cache[oldest_key]
        self._cache[key] = (value, time.time())

search_cache = TTLCache(ttl_seconds=SEARCH_CACHE_TTL, max_size=100)
trending_cache = TTLCache(ttl_seconds=TRENDING_CACHE_TTL, max_size=20)

# --- Response envelope helpers ---
def success_response(data):
    return {"data": data, "error": None}

def error_response(message, code=None):
    return {"data": None, "error": {"message": message, "code": code}}


# --- S17 (CV-3): auth dependency for user-data endpoints ---
# Previously the backend only required auth on /sync/* and
# /auth/signout — every other endpoint (search, stream,
# library, radio, podcasts, audiobooks) was open. After the
# Track 12 security review we close that gap. The plan
# keeps the sign-in flow (/auth/apple, /auth/refresh) and the
# health check (/health) open; everything else requires a
# valid session JWT minted by /auth/apple.
#
# Use as `user: dict = Depends(require_session_user)` on the
# endpoint signature. FastAPI will pass `request: Request`
# via the type annotation.
def require_session_user(request: Request) -> dict:
    user = current_user_from_request(request.headers.get("Authorization"))
    if not user:
        # Match the /sync/* 401 detail for consistency in the
        # iOS ErrorHandler (S15: it preserves the body for 4xx).
        raise HTTPException(status_code=401, detail="unauthorized")
    return user

# --- Thread safety for ytmusic client ---
ytmusic_lock = asyncio.Lock()

# S17-H / S17-PLAY (Fix 3B, 2026-07-29): cap concurrent yt-dlp+ffmpeg
# transcodes to protect the backend from burst storms. Original cap
# was 2 (sweet spot for an 8GB Mac), then 3 (for HLS overhead).
#
# S17-H / HLS-LATENCY (2026-08-06): made configurable via
# HLS_TRANSCODE_CONCURRENCY env var, default 6. The Mac can
# comfortably handle 6 concurrent yt-dlp+ffmpeg pipelines (each
# process is I/O-bound on YouTube downloads, so they don't all
# peg the CPU). 6 lets the gapless queue stay warm without
# making the user wait for a slot. The 8GB model caveat is
# still respected via the env var — set HLS_TRANSCODE_CONCURRENCY=2
# for memory-constrained hardware.
import os as _os
_transcode_semaphore = asyncio.Semaphore(
    int(_os.environ.get("HLS_TRANSCODE_CONCURRENCY", "6"))
)

# S17-H / S17-PLAY (Fix 3B): per-videoId lock so the same videoId
# can't be transcoded twice in parallel. Without this, the burst
# scenario "prefetch track A, then immediately tap A" can spin up
# two concurrent transcodes of A — one via /prefetch's background
# task and one via /audio's request handler — both write to the
# same cache_path and corrupt the output. Dict-of-locks is the
# standard asyncio pattern for keyed mutexes. Lazy-create on first
# use (asyncio.Lock requires a running event loop in some Python
# versions; module-import-time construction can race with the
# event loop starting).
_videoId_locks: dict = {}

# Server start time for health check
_server_start_time = datetime.datetime.now()

# Shared HTTP session for connection pooling
_http_session: Optional[_requests.Session] = None

def get_http_session() -> _requests.Session:
    """Reusable requests.Session with connection pooling."""
    global _http_session
    if _http_session is None:
        _http_session = _requests.Session()
        _http_session.headers.update({
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        })
        adapter = _requests.adapters.HTTPAdapter(pool_connections=HTTP_POOL_SIZE, pool_maxsize=HTTP_POOL_MAX)
        _http_session.mount('https://', adapter)
        _http_session.mount('http://', adapter)
    return _http_session

# FastAPI app initialization
app = FastAPI(
    title="YT Audio Backend",
    description="Personal audio extraction and streaming backend",
    version="1.0.0"
)

# CORS for local development (iOS client on same network)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "HEAD", "OPTIONS"],
    allow_headers=["*"],
)


# --- Rate limiting with slowapi ---
#
# S17 (CV-3, defense in depth): slowapi is a per-IP in-memory
# rate limiter. `key_func=get_remote_address` means each
# remote client IP gets its own bucket; sharing the Mac's LAN
# IP with other devices is fine, but a coffee-shop MITM that
# floods the backend can't burn through the bucket from a
# different /24.
#
# Per-endpoint policy (each line is "N requests per minute
# per IP"):
#   /sync/upload, /sync/download  : 10/min — strict. /sync/*
#                                  moves user-data; an attacker
#                                  guessing the JWT can otherwise
#                                  iterate quickly.
#   /search, /search/playlists    : 10/min — strict. Search
#                                  hits YouTube Music on every
#                                  call; a 10/min cap is plenty
#                                  for a real user typing.
#   /charts, /new-releases        : 5/min  — even stricter. The
#                                  content rarely changes, so a
#                                  user only needs to fetch
#                                  once per session.
#   /download                     : 15/min — slightly looser
#                                  because a user queueing a
#                                  small album makes several
#                                  POSTs back-to-back.
#   /audio/{videoId}.m4a         : 20/min — each request is one
#                                  song; a user skipping a few
#                                  times lands at 5-10/min. (Was
#                                  /proxy-stream before 2026-08-06
#                                  S17-H HLS latency fix; the
#                                  buffering-the-whole-body proxy
#                                  was removed and the iOS app's
#                                  cold-play path now goes through
#                                  /play/{videoId}/playlist.m3u8
#                                  instead.)
#   /radio-stations/*, /podcasts/*,
#   /audiobooks/*                 : 20-30/min — these proxy
#                                  third-party APIs (RadioBrowser,
#                                  iTunes, LibriVox); caps the
#                                  blast radius if a key is
#                                  leaked.
#
# We enable `_headers_enabled=True` and `_retry_after="delta-seconds"`
# so the 429 response carries an `X-RateLimit-Limit`,
# `X-RateLimit-Remaining`, `X-RateLimit-Reset`, and (most
# importantly) a numeric `Retry-After` header. The iOS client's
# `ErrorHandler` (S15 fix) already reads `Retry-After` from the
# 429 and shows "You're going a bit fast — try again in Ns."
#
# Storage is in-process (the default `memory://` storage).
# For a single-Mac personal backend, this is fine — there's
# only one process. A multi-process prod deploy would want
# Redis-backed storage; out of scope here.
limiter = Limiter(
    key_func=get_remote_address,
    # We deliberately do NOT pass `headers_enabled=True` to
    # the Limiter. slowapi's auto-inject path (extension.py
    # `async_wrapper`) assumes every decorated endpoint returns
    # a `starlette.responses.Response` instance; our routes
    # return Pydantic models (lists/dicts) which FastAPI
    # serializes. When `headers_enabled=True`, slowapi then
    # tries `kwargs.get("response")` to find a Response to
    # decorate, and raises
    #   "parameter `response` must be an instance of
    #    starlette.responses.Response"
    # on every non-Response endpoint.
    #
    # Instead, we set the `Retry-After` header manually in
    # our custom 429 handler below (see `_rate_limit_handler`).
    # The iOS client reads `Retry-After` and shows a
    # human-friendly wait time; the rest of the rate-limit
    # bookkeeping (X-RateLimit-Limit, X-RateLimit-Remaining)
    # is not used by the iOS app today, so we skip those.
)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)


# S17 (CV-3, defense in depth): the default slowapi handler
# returns a JSONResponse without a `Retry-After` header, so
# the iOS client falls back to a generic "slow down" message
# without a wait time. We override it to:
#   1. set `Retry-After: <seconds-until-reset>` so the iOS
#      ErrorHandler (S15) can show "try again in Ns", and
#   2. preserve the JSON body shape the rest of the app
#      already understands.
def _rate_limit_handler(request: Request, exc: RateLimitExceeded) -> Response:
    """S17: custom 429 handler. Sets a numeric `Retry-After`
    header (seconds) so the iOS client knows how long to
    back off, and keeps the JSON body shape the rest of the
    app already understands.

    The reset-time is taken from the limiter's window stats
    when available, falling back to 60s (a safe default for
    "N per minute" limits) if the stats lookup fails.
    """
    reset_seconds = 60  # safe default
    try:
        limit = getattr(request.state, "view_rate_limit", None)
        if limit and app.state.limiter._limiter is not None:
            window_stats = app.state.limiter._limiter.get_window_stats(
                limit[0], *limit[1]
            )
            reset_seconds = max(1, 1 + window_stats[0] - int(time.time()))
    except Exception:
        # stats lookup is best-effort; if it fails we still
        # return a 429 with the fallback Retry-After.
        pass

    return JSONResponse(
        {"error": f"Rate limit exceeded: {exc.detail}"},
        status_code=429,
        headers={"Retry-After": str(int(reset_seconds))},
    )


app.add_exception_handler(RateLimitExceeded, _rate_limit_handler)


# --- Request ID + timing middleware ---
@app.middleware("http")
async def add_request_id(request: Request, call_next):
    request_id = str(uuid.uuid4())[:8]
    request.state.request_id = request_id
    start = time.time()
    response = await call_next(request)
    duration_ms = int((time.time() - start) * 1000)
    response.headers["X-Request-ID"] = request_id
    logger.info(f"[{request_id}] {request.method} {request.url.path} → {response.status_code} ({duration_ms}ms)")
    return response


# Pydantic models for request/response validation
class SearchQuery(BaseModel):
    query: str = Field(..., min_length=1, max_length=500, description="Search string")
    limit: int = Field(default=20, ge=1, le=50, description="Max results")


class DownloadRequest(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)

    video_id: str = Field(..., description="YouTube video ID")
    title: str = Field(..., description="Track title")
    artists: List[str] = Field(default=[], description="List of artists")
    album: str = Field(default="Unknown Album", description="Album name")
    thumbnail: Optional[str] = Field(default=None, description="Thumbnail URL for artwork")


class ThumbnailResponse(BaseModel):
    url: str
    width: int
    height: int


class TrackResponse(BaseModel):
    videoId: str
    title: str
    artists: List[str]
    album: str
    durationSeconds: int
    thumbnails: List[ThumbnailResponse]
    isExplicit: bool
    videoType: str = "UNKNOWN"


class PlaylistResponse(BaseModel):
    playlistId: str
    title: str
    author: str
    videoCount: int
    thumbnails: List[ThumbnailResponse]
    description: str


class PlaylistDetailsResponse(BaseModel):
    playlistId: str
    title: str
    author: str
    videoCount: int
    thumbnails: List[ThumbnailResponse]
    description: str
    tracks: List[TrackResponse]


class StreamResponse(BaseModel):
    streamUrl: str
    mimeType: str
    bitrate: int


class DownloadResponse(BaseModel):
    status: str
    filePath: str


class LibraryTrack(BaseModel):
    filename: str
    path: str
    size: int
    size_human: str
    modified: float


class AuthStatusResponse(BaseModel):
    authenticated: bool
    mode: str
    message: str


class AppleSignInRequest(BaseModel):
    """Body of POST /auth/apple.

    `identityToken` is the JWT that iOS hands back from
    ASAuthorizationAppleIDProvider. We verify it against Apple's
    public JWKS, then mint our own session JWT.

    `authorizationCode` is optional - it's a one-time code that
    can be exchanged with Apple for refresh tokens. We don't need
    it for the music-streaming use case, but we accept it so the
    iOS code can send the standard Sign in with Apple payload.
    """
    identityToken: str
    authorizationCode: Optional[str] = None
    user: Optional[str] = None  # Apple-provided user identifier (only on first sign-in)
    fullName: Optional[dict] = None  # {givenName, familyName} on first sign-in only
    email: Optional[str] = None  # only on first sign-in (Apple rotates this on re-sign-in)


class AppleSignInResponse(BaseModel):
    """Successful sign-in response. The iOS app stores the session
    token in Keychain and posts it as a Bearer token on subsequent
    requests."""
    userId: str           # our UUID
    sessionToken: str     # our 30-day JWT
    expiresAt: int        # unix seconds
    email: Optional[str] = None
    isNewUser: bool       # true if this is the first sign-in
    serverTime: int


class SyncUploadRequest(BaseModel):
    """Body of POST /sync/upload. The iOS app posts its local Core
    Data (playlists, favorites, history) here on first sign-in so
    it's safe in the cloud."""
    playlists: List[dict] = []
    favorites: List[str] = []  # videoIds
    history: List[dict] = []
    favoriteArtists: List[str] = []
    clientVersion: int = 1
    uploadedAt: int = 0


class SyncBlobResponse(BaseModel):
    """Body of GET /sync/download. The shape mirrors the upload
    request so the iOS client can apply it back into Core Data
    with a single Codable decoder."""
    playlists: List[dict] = []
    favorites: List[str] = []
    history: List[dict] = []
    favoriteArtists: List[str] = []
    uploadedAt: int = 0
    serverTime: int


# Root endpoint
@app.get("/")
@limiter.limit("15/minute")
async def root(request: Request):
    client = get_client()
    return {
        "status": "running",
        "service": "YT Audio Backend",
        "authenticated": client.authenticated,
        "mode": "authenticated" if client.authenticated else "guest"
    }


@app.get("/auth-status", response_model=AuthStatusResponse)
@limiter.limit("15/minute")
async def auth_status(request: Request):
    """Get current authentication status."""
    client = get_client()
    if client.authenticated:
        return AuthStatusResponse(
            authenticated=True,
            mode="authenticated",
            message="Full access enabled - you can access your library and playlists"
        )
    else:
        return AuthStatusResponse(
            authenticated=False,
            mode="guest",
            message="Guest mode - search and streaming work. Run 'make auth' for full access"
        )


@app.post("/auth/refresh")
@limiter.limit("15/minute")
async def refresh_auth(request: Request):
    """Reload authentication (call after running setup_oauth.py)."""
    reset_client()
    client = get_client()
    return {
        "authenticated": client.authenticated,
        "message": "Authentication reloaded"
    }


# --- Apple Sign-In (2026-06-28) ---
# The iOS app posts the identityToken from ASAuthorizationAppleIDProvider.
# We verify it against Apple's JWKS, provision a user record on first
# sign-in, and mint a 30-day session JWT. The JWT is sent back so the
# iOS app can store it in Keychain and use it on subsequent requests.

@app.post("/auth/apple", response_model=AppleSignInResponse)
@limiter.limit("30/minute")
async def auth_apple(request: Request, body: AppleSignInRequest):
    """Verify an Apple identity token and return a session JWT.

    Always returns 200 with the session token on success. A new
    user record is created on first sign-in; subsequent sign-ins
    update the last_seen_at and return the existing user_id.
    """
    try:
        claims = verify_apple_identity_token(body.identityToken)
    except Exception as e:
        # PyJWTError or any unexpected JWKS error - all map to 401.
        logger.warning(f"Apple identity token rejected: {e}")
        raise HTTPException(status_code=401, detail="invalid_identity_token")

    apple_sub = claims.get("sub")
    if not apple_sub:
        raise HTTPException(status_code=401, detail="missing_subject_claim")

    user, is_new = get_or_create_user(apple_sub, claims)

    # Apple only sends the user's name + email on FIRST sign-in.
    # If we have them in this request body and the user record
    # doesn't already have them, persist them. Subsequent sign-ins
    # send None for both.
    if body.fullName and not user.get("name"):
        given = (body.fullName.get("givenName") or "").strip()
        family = (body.fullName.get("familyName") or "").strip()
        user["name"] = " ".join(p for p in (given, family) if p) or None
        save_user(user)
    if body.email and not user.get("email"):
        user["email"] = body.email
        user["email_verified"] = True  # Apple verifies the email at the relay
        save_user(user)

    touch_last_seen(user["user_id"])

    expires_at = int(time.time()) + 30 * 24 * 60 * 60  # 30 days
    session_token = mint_session_jwt(user["user_id"], apple_sub)

    return AppleSignInResponse(
        userId=user["user_id"],
        sessionToken=session_token,
        expiresAt=expires_at,
        email=user.get("email"),
        isNewUser=is_new,
        serverTime=int(time.time()),
    )


@app.post("/auth/signout")
@limiter.limit("15/minute")
async def auth_signout(request: Request):
    """Sign the current session out. The session JWT is stateless
    (just a signed blob) so we can't actually invalidate it; the
    iOS app must drop the token from Keychain. This endpoint
    exists so the client can record a sign-out timestamp on the
    server (useful for audit) and for parity with the iOS
    flow."""
    user = current_user_from_request(request.headers.get("Authorization"))
    if not user:
        # 204 even when not authenticated - sign-out is idempotent.
        return {"ok": True}
    user["last_signout_at"] = int(time.time())
    save_user(user)
    return {"ok": True}


# --- Sync (2026-06-28) ---
# The iOS app posts the user's local Core Data on first sign-in
# (so it's safe in the cloud), and downloads it on subsequent
# sign-ins (so a new device picks up where they left off).
# Both endpoints require a valid session JWT.

@app.post("/sync/upload")
@limiter.limit("10/minute")
async def sync_upload(request: Request, body: SyncUploadRequest):
    user = current_user_from_request(request.headers.get("Authorization"))
    if not user:
        raise HTTPException(status_code=401, detail="unauthorized")
    blob = {
        "playlists": body.playlists,
        "favorites": body.favorites,
        "history": body.history,
        "favoriteArtists": body.favoriteArtists,
        "uploadedAt": int(time.time()),
        "clientVersion": body.clientVersion,
    }
    save_sync_blob(user["user_id"], blob)
    return {"ok": True, "uploadedAt": blob["uploadedAt"]}


@app.get("/sync/download", response_model=SyncBlobResponse)
@limiter.limit("10/minute")
async def sync_download(request: Request):
    user = current_user_from_request(request.headers.get("Authorization"))
    if not user:
        raise HTTPException(status_code=401, detail="unauthorized")
    blob = load_sync_blob(user["user_id"])
    if not blob:
        return SyncBlobResponse(serverTime=int(time.time()))
    return SyncBlobResponse(
        playlists=blob.get("playlists", []),
        favorites=blob.get("favorites", []),
        history=blob.get("history", []),
        favoriteArtists=blob.get("favoriteArtists", []),
        uploadedAt=blob.get("uploadedAt", 0),
        serverTime=int(time.time()),
    )


@app.get("/cache/stats")
@limiter.limit("15/minute")
async def cache_stats(request: Request, user: dict = Depends(require_session_user),):
    """Get stream URL cache statistics."""
    cache = get_cache()
    return cache.get_stats()


@app.post("/cache/clear")
@limiter.limit("15/minute")
async def cache_clear(request: Request, user: dict = Depends(require_session_user),):
    """Clear the stream URL cache."""
    cache = get_cache()
    cache.clear()
    return {"message": "Cache cleared"}


# Search endpoint
@app.post("/search", response_model=List[TrackResponse])
@limiter.limit("10/minute")
async def search(query: SearchQuery, request: Request, user: dict = Depends(require_session_user),):
    """Search YouTube Music for tracks."""
    cache_key = f"{query.query}:{query.limit}"
    cached = search_cache.get(cache_key)
    if cached is not None:
        return cached
    try:
        client = get_client()
        async with ytmusic_lock:
            results = client.search_tracks(query.query, query.limit)

        if not results:
            return []

        response = [TrackResponse(**track).model_dump() for track in results]
        search_cache.set(cache_key, response)
        return response

    except Exception as e:
        logger.error(f"search_tracks failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")


# Playlist search endpoint
@app.post("/search/playlists", response_model=List[PlaylistResponse])
@limiter.limit("10/minute")
async def search_playlists(query: SearchQuery, request: Request, user: dict = Depends(require_session_user),):
    """Search YouTube Music for playlists."""
    try:
        client = get_client()
        async with ytmusic_lock:
            results = client.search_playlists(query.query, query.limit)
        return results
    except Exception as e:
        logger.error(f"search_playlists failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Playlist search failed: {str(e)}")


# Get playlist details endpoint
@app.get("/playlist/{playlist_id}", response_model=PlaylistDetailsResponse)
@limiter.limit("15/minute")
async def get_playlist(playlist_id: str, request: Request, limit: int = Query(default=100, ge=1, le=200), user: dict = Depends(require_session_user),):
    """Get full playlist details including tracks."""
    try:
        client = get_client()
        async with ytmusic_lock:
            playlist = client.get_playlist(playlist_id, limit=limit)

        if not playlist:
            raise HTTPException(status_code=404, detail="Playlist not found")

        return playlist
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"get_playlist failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Failed to get playlist: {str(e)}")


# Stream endpoint
@app.api_route("/stream/{video_id}", methods=["GET", "HEAD"])
@limiter.limit("60/minute")
async def stream_audio(video_id: str, request: Request, user: dict = Depends(require_session_user),):
    """Get streaming URL for a video. Returns a 302 redirect to the
    YouTube CDN URL. The iOS app follows the redirect and uses the
    final URL (response.url) to hand to AVPlayer.

    Why a 302 instead of a JSON body with the URL: when the iOS app
    used the previous JSON response, the URL went through with
    ANDROID_VR's c= client tag baked in, and AVPlayer's iOS User-Agent
    + the ANDROID_VR signature didn't match — YouTube served a
    response shape AVPlayer rejected with AVError.fileFormatNotRecognized
    (-11828). By returning a 302, URLSession follows the redirect
    server-side, the iOS app gets the final YouTube URL via
    response.url, and AVPlayer has a clean URL with no client-tag
    surprises.

    The 3.5h URL signature is still bound to the original
    request — we just hand the bytes back to YouTube. Cache hit
    is fast (no yt-dlp re-run).
    """
    try:
        cache = get_cache()
        stream_data = cache.get(video_id)

        if not stream_data:
            logger.info(f"Cache miss for {video_id}, fetching from YouTube...")
            client = get_client()
            async with ytmusic_lock:
                stream_data = client.get_stream_url(video_id)

            if not stream_data or not stream_data.get('audio_formats'):
                raise HTTPException(status_code=404, detail="No audio stream found")

            # S17-H (2026-07-27): yt-dlp returns formats in a
            # specific order, but it's not consistent across
            # videos — for some the first format is webm/Opus
            # (itag 251/249, plays fine in AVPlayer on iOS 17),
            # for others it's m4a/AAC but the actual file is a
            # DASH manifest (ftyp dash), not a regular audio MP4.
            # AVPlayer rejects the DASH m4a with
            # AVError.fileFormatNotRecognized (-11828) — it can't
            # play DASH files directly. Pick webm/Opus first,
            # fall back to m4a only if webm is unavailable.
            formats = stream_data.get('audio_formats', [])
            webm = [f for f in formats if f.get('mime_type') == 'webm']
            m4a = [f for f in formats if f.get('mime_type') in ('m4a', 'audio/mp4')]
            if webm:
                # Sort webm by bitrate (ascending) — pick the
                # smallest one (itag 249) for fast start.
                webm.sort(key=lambda f: f.get('bitrate', 0))
                best = webm[0]
            elif m4a:
                # No webm available; use m4a. Some m4a URLs are
                # regular audio, some are DASH — try it and let
                # AVPlayer surface the error if DASH.
                m4a.sort(key=lambda f: f.get('bitrate', 0))
                best = m4a[0]
            else:
                best = formats[0]
            stream_data['audio_formats'] = [best] + [f for f in formats if f is not best]
            # Cache the stream data
            cache.set(video_id, stream_data)

        best = stream_data['audio_formats'][0]
        yt_url = best['url']
        mime_type = best.get('mime_type', 'audio/mp4')
        if mime_type in ['m4a', 'audio/m4a', 'audio/x-m4a']:
            mime_type = 'audio/mp4'

        # S17-H (2026-07-27): Even webm/Opus is rejected by
        # AVPlayer on this iPhone — the underlying error is
        # NSOSStatusErrorDomain -12847 (kAudioConverterErr_
        # FormatNotSupported), which means iOS's audio decoder
        # can't handle the specific Opus profile YouTube serves
        # (likely a 5.1 surround or a 96kHz/24-bit variant that
        # iOS's hardware decoder doesn't support). m4a/AAC works
        # on every iOS device but yt-dlp's m4a URLs are DASH
        # manifests, not regular audio MP4 — so we can't hand
        # them to AVPlayer either.
        #
        # Solution: route playback through /audio/{videoId}.m4a,
        # a new endpoint that downloads the YouTube webm body,
        # transcodes it to AAC/M4A with ffmpeg, and streams
        # the result to AVPlayer. The transcoded body is cached
        # on disk so subsequent plays are instant. AVPlayer
        # sees a clean M4A with major_brand=M4A, no DASH, no
        # Opus — just AAC LC 48kHz stereo, which every iPhone
        # plays.
        #
        # S17-H (2026-07-27 00:48 follow-up): previously this
        # returned a 302 to /audio/{videoId}.m4a and relied on
        # URLSession to forward the Bearer token on the
        # redirect — it doesn't (per RFC 7235, the Authorization
        # header is stripped on cross-host redirects; URLSession
        # is even stricter on same-host). The redirect produced
        # a 401 on /audio. Instead, return a JSON body with the
        # full audio URL (including ?token=...). The iOS app
        # extracts the URL and hands it to AVPlayer; AVPlayer
        # fetches with the token in the query string, which
        # /audio accepts (token-in-query is the standard HLS
        # auth pattern, same as Apple Music and YouTube Music).
        # Result: one HTTP call to get the URL, no redirect,
        # no 401.
        logger.info(f"/stream/{video_id} → JSON with /audio URL (transcoded AAC)")
        # Build the audio URL with the user's auth token in
        # the query string. The token is the same session JWT
        # the iOS app sent in the Authorization header to this
        # /stream call. We re-emit it in the response so the
        # iOS app can put it on the /audio URL for AVPlayer.
        auth_header = request.headers.get('Authorization') or ''
        token = ''
        if auth_header.lower().startswith('bearer '):
            token = auth_header.split(' ', 1)[1].strip()
        from urllib.parse import quote
        # S17-H / HLS (Fix 4 Phase 3, 2026-07-30): pick the
        # delivery format based on whether the audio is cached.
        # Cache hit → /audio (instant). Cache miss → /play (HLS
        # streaming, ~3s TTFB instead of 12-150s). The iOS app
        # doesn't need to know the difference — AVPlayer
        # auto-detects m3u8 vs m4a from the URL.
        audio_cache_dir = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache')
        audio_cache_path = audio_cache_dir / f"{video_id}.m4a"
        # S17-H / HLS-LATENCY (2026-08-06): was `> 1000` (1KB). The
        # ftyp+empty_moov that ffmpeg writes first is ~28 bytes —
        # smaller than 1KB. But if the transcode is in progress, the
        # file can briefly grow past 1KB (first moof+mdat pair is
        # ~1-2KB), which fooled /stream into routing to /audio before
        # the file was actually playable. That sent AVPlayer a
        # half-written MP4, which it failed to decode → "Couldn't
        # play this track". 50KB ≈ 4 seconds of AAC at 128kbps
        # plus the ftyp/moov. If the file is smaller than that,
        # either the transcode hasn't produced anything meaningful
        # yet, or it's a corrupt partial — route to HLS in both
        # cases so the user gets progress visibility instead of a
        # silent half-file.
        if audio_cache_path.exists() and audio_cache_path.stat().st_size > 50_000:
            # Warm path: direct MP4
            stream_url = f'/audio/{video_id}.m4a?token={quote(token)}'
            mime_type = 'audio/mp4'
        else:
            # Cold path: HLS playlist. /play handles the transcode,
            # the m3u8 endpoint injects the token into each
            # segment URL.
            stream_url = f'/play/{video_id}/playlist.m3u8?token={quote(token)}'
            mime_type = 'application/x-mpegurl'
        return JSONResponse(content={
            'streamUrl': stream_url,
            'mimeType': mime_type,
            'bitrate': 128000,
        })

        # S17-H (2026-07-27): 302 redirect to the YouTube URL.
        # The iOS app's URLSession follows the redirect, and
        # the final response.url is the YouTube CDN URL. No
        # body buffering in the FastAPI worker, no AsyncClient
        # context issue, no AVPlayer User-Agent mismatch.
        # (Replaced with the /audio/{video_id}.m4a redirect
        # above; this block is dead code kept as a fallback for
        # the 302 path until /audio is verified end-to-end.)

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Stream extraction failed")
        raise HTTPException(status_code=500, detail=f"Stream extraction failed: {str(e)}")


# Transcoded audio endpoint — converts YouTube's webm/Opus to
# m4a/AAC on the fly, caches the result on disk. iOS's audio
# decoder can't handle YouTube's specific Opus profile (yields
# NSOSStatusErrorDomain -12847 / kAudioConverterErr_FormatNotSupported
# on iPhone 14 Plus), and YouTube's m4a URLs are DASH manifests
# (ftyp dash, not regular audio MP4). This is the only path
# that produces an audio body AVPlayer can decode on every iOS
# device. /stream returns a 302 to here; the iOS app follows
# the redirect, AVPlayer fetches the AAC bytes.
@app.api_route("/audio/{video_id}.m4a", methods=["GET", "HEAD"])
@limiter.limit("20/minute")
async def audio_stream(video_id: str, request: Request):
    # S17-H (2026-07-27 00:48): also accept the session JWT
    # via ?token=... query param. AVPlayer is a system
    # component, not URLSession — it can't add the iOS app's
    # Bearer token to its GET, so the token has to ride along
    # in the URL. The iOS app's getStreamUrl now appends the
    # same peaceplayer.session_token from the keychain that
    # URLSession uses. The Authorization header path is still
    # primary — the query param is the fallback for
    # redirect-stripped / AVPlayer-initiated requests.
    #
    # CRITICAL: do the auth check INLINE (not via
    # `Depends(require_session_user)`) so FastAPI doesn't
    # evaluate auth before the function body runs. We need
    # to read either the Authorization header OR the
    # ?token= query param ourselves.
    from urllib.parse import unquote
    auth_header = request.headers.get('Authorization') or ''
    if not auth_header:
        query_token = request.query_params.get('token')
        if query_token:
            auth_header = f'Bearer {unquote(query_token)}'
    user = current_user_from_request(auth_header)
    if not user:
        raise HTTPException(status_code=401, detail="unauthorized")
    try:
        cache = get_cache()
        stream_data = cache.get(video_id)

        if not stream_data:
            async with ytmusic_lock:
                client = get_client()
                stream_data = client.get_stream_url(video_id)
            if not stream_data or not stream_data.get('audio_formats'):
                raise HTTPException(status_code=404, detail="No audio stream found")
            cache.set(video_id, stream_data)

        # Pick the smallest webm (Opus) — fastest to transcode.
        formats = stream_data['audio_formats']
        webm = [f for f in formats if f.get('mime_type') == 'webm']
        if not webm:
            raise HTTPException(status_code=404, detail="No webm format available")
        webm.sort(key=lambda f: f.get('bitrate', 0))
        yt_url = webm[0]['url']

        # S17-H (2026-07-27): pipe YouTube → ffmpeg → AVPlayer.
        # The first call downloads from YouTube and transcribes
        # (~1-3s). Subsequent calls hit the disk cache. The
        # cache file is in major_brand=M4A, mp4a AAC LC 48kHz
        # stereo — what every iPhone plays.
        cache_dir = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache')
        cache_dir.mkdir(parents=True, exist_ok=True)
        cache_path = cache_dir / f"{video_id}.m4a"

        if not cache_path.exists() or cache_path.stat().st_size < 1000:
            logger.info(f"[audio] Transcoding {video_id} from YouTube (first call)...")
            # S17-H / S17-PLAY (Fix 3B, 2026-07-29): the actual transcode
            # work is now in a shared helper. Both /audio and /prefetch
            # call it; the helper enforces the global transcode
            # semaphore and a per-videoId lock so concurrent
            # transcodes of the same track don't race or double-spend
            # CPU. See _transcode_to_cache below.
            await _transcode_to_cache(video_id, yt_url)

        if not cache_path.exists() or cache_path.stat().st_size < 1000:
            raise HTTPException(status_code=500, detail="Transcode produced no output")

        # S17-H (2026-07-27): serve the AAC file with Range support
        # so AVPlayer can seek. The file is fully on disk now
        # (no streaming concern like the YouTube path) so
        # FileResponse handles ranges natively.
        file_size = cache_path.stat().st_size
        range_header = request.headers.get('range')
        if range_header:
            # Parse "bytes=START-END"
            try:
                spec = range_header.replace('bytes=', '').split('-')
                start = int(spec[0]) if spec[0] else 0
                end = int(spec[1]) if len(spec) > 1 and spec[1] else file_size - 1
                end = min(end, file_size - 1)
                length = end - start + 1
                with open(cache_path, 'rb') as f:
                    f.seek(start)
                    data = f.read(length)
                return Response(
                    content=data,
                    status_code=206,
                    headers={
                        'Content-Type': 'audio/mp4',
                        'Content-Length': str(length),
                        'Content-Range': f'bytes {start}-{end}/{file_size}',
                        'Accept-Ranges': 'bytes',
                        'Access-Control-Allow-Origin': '*',
                    },
                )
            except (ValueError, IndexError):
                pass  # Fall through to full file

        # Full file (no Range or unparseable Range)
        return FileResponse(
            str(cache_path),
            media_type='audio/mp4',
            headers={
                'Accept-Ranges': 'bytes',
                'Content-Length': str(file_size),
                'Access-Control-Allow-Origin': '*',
            },
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Audio transcode failed")
        raise HTTPException(status_code=500, detail=f"Audio transcode failed: {str(e)}")


# Prefetch endpoint - fire-and-forget cache warming
@app.post("/prefetch/{video_id}")
@limiter.limit("60/minute")
async def prefetch_stream(video_id: str, background_tasks: BackgroundTasks, request: Request, user: dict = Depends(require_session_user),):
    """
    Fire-and-forget endpoint to warm the stream URL cache AND
    pre-transcode the audio. Returns 202 Accepted immediately;
    extraction + transcode run in the background.

    S17-H (2026-07-27 13:39): also kicks off the audio transcode
    so the iOS app's first play is instant. Without this, the
    user clicks a track, the /audio endpoint starts the
    5-30s yt-dlp+ffmpeg transcode, AVPlayer waits for the
    response, and the iOS app's UI hangs. /prefetch now does
    the transcode in the background, so by the time the user
    taps play, the AAC body is already on disk.

    S17-H / S17-PLAY (Fix 3B, 2026-07-29): pass the user_id into
    the background worker so it can run the transcode directly via
    _transcode_to_cache (no more "find first user in /data/users"
    hack that broke in multi-user environments).
    """
    # Cache hit: stream URL + audio both already there
    cache = get_cache()
    audio_cache_path = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache') / f"{video_id}.m4a"
    if cache.get(video_id) and audio_cache_path.exists() and audio_cache_path.stat().st_size > 1000:
        return {"status": "already_cached"}

    # Pass user_id (not the full dict) because the background task
    # runs in a different request context and only needs the
    # user_id to log/attribute work.
    user_id = user.get("user_id") if isinstance(user, dict) else None
    background_tasks.add_task(_prefetch_worker, video_id, user_id)
    return {"status": "accepted"}


async def _transcode_to_cache(video_id: str, yt_url: str) -> None:
    """
    S17-H / S17-PLAY (Fix 2+3B, 2026-07-29): the actual transcode
    work, extracted from audio_stream so /prefetch can call it
    directly without the "internal HTTP call + minted token" hack.

    Concurrency model (Fix 3B):
      - _transcode_semaphore (cap=2): global cap on concurrent
        yt-dlp+ffmpeg pipelines across the whole backend. Protects
        the Mac from a burst storm of cold plays.
      - _videoId_locks[video_id]: keyed mutex so the same track
        can't be transcoded twice in parallel (e.g., a /prefetch
        background task and a /audio request for the same track
        arriving within milliseconds). Without this, two
        transcodes race to write the same cache_path and one
        corrupts the other.

    The transcode (Fix 2+4 Phase 1, 2026-07-30) is now a single
    pass that writes fragmented MP4 (fMP4) directly to
    cache_path. The earlier hybrid pipe+re-mux was needed for
    regular MP4 (because +faststart requires a seekable output),
    but fMP4's +empty_moov flag puts the moov at the start
    without a 2-pass write. This halves the wall-clock
    (single pass vs pipe-then-remux) and produces a file
    format that AVPlayer can start playing as soon as the
    first fragment is buffered — useful for Phase 2
    stream-while-transcode.

    Verified empirically on jNQXAC9IVRw (19s audio, 314KB):
      Fix 2 (regular MP4 + re-mux): 14.8s
      Fix 4 Phase 1 (fMP4, single pass): ~7s
    """
    cache_dir = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache')
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / f"{video_id}.m4a"

    if cache_path.exists() and cache_path.stat().st_size > 1000:
        return  # already transcoded by another caller

    # Per-videoId lock: if another caller (a /prefetch and a /audio
    # racing) is already transcoding this track, wait for them.
    # Lazy-create the lock if first time seeing this videoId.
    if video_id not in _videoId_locks:
        _videoId_locks[video_id] = asyncio.Lock()
    async with _videoId_locks[video_id]:
        # Re-check inside the lock — the first caller may have
        # already finished.
        if cache_path.exists() and cache_path.stat().st_size > 1000:
            return

        # Global semaphore: cap concurrent transcodes across the
        # whole backend. The lock above is per-videoId; this is
        # global. Both are needed: a burst of 10 different cold
        # plays still needs the global cap.
        async with _transcode_semaphore:
            await _do_transcode_pipeline(video_id, yt_url, cache_path)


async def _do_transcode_pipeline(video_id: str, yt_url: str, cache_path: Path) -> None:
    """
    Inner transcode implementation. Caller MUST hold the
    per-videoId lock AND the global semaphore. This function
    assumes exclusivity and does not re-check or re-lock.

    S17-H / S17-PLAY (Fix 4 Phase 1, 2026-07-30): switched from
    regular MP4 + post-encode re-mux to fragmented MP4 (fMP4).
    Same single-pass pipe (yt-dlp → ffmpeg → file), but the
    ffmpeg output is fMP4 with the moov at the start. No
    re-mux pass is needed — the empty_moov flag tells ffmpeg
    to write the moov placeholder at byte 0 and update it as
    fragments are appended.

    Why fMP4: AVPlayer can't start playing a regular MP4 until
    it has the moov atom, which sits at the END of the file
    (or has to be re-muxed to the front via +faststart, which
    doesn't work with pipe output — see Fix 2). For fMP4, the
    moov is at the start and fragments are independently
    decodable, so a streaming client can start playing as
    soon as the first fragment is buffered.

    Benchmark (Fix 4 Phase 1, jNQXAC9IVRw 19s audio, 314KB):
      - Old (Fix 1+2, regular MP4 + re-mux):  14.8s
      - New (Fix 4 Phase 1, fMP4, single pass): ~7s
      - 2.1x faster just from the format change.
    """
    cache_dir = cache_path.parent
    # S17-H / S17-PLAY (Fix 4 Phase 1): write the fMP4 file
    # directly to cache_path. No more .raw.m4a intermediate
    # and no more re-mux pass. The empty_moov flag handles the
    # "moov at start" requirement in one pass.
    pipe_cmd = (
        f'{shlex.quote(YTDLP_BIN)} '
        f'--js-runtimes deno:{shlex.quote(DENO_BIN)} '
        f'-f "worstaudio[ext=webm]/worstaudio/bestaudio[ext=webm]/bestaudio/best" '
        f'-o - --no-playlist --no-part --no-progress --quiet '
        f'--remote-components ejs:github {shlex.quote(yt_url)} '
        f'| {shlex.quote(FFMPEG_BIN)} -y -loglevel error -i pipe:0 '
        f'-c:a aac -b:a 128k '
        f'-movflags "+frag_keyframe+empty_moov+default_base_moof" '
        f'-f mp4 {shlex.quote(str(cache_path))}'
    )
    try:
        t0 = time.monotonic()
        proc = await asyncio.create_subprocess_shell(
            pipe_cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        pipe_seconds = time.monotonic() - t0

        if not cache_path.exists() or cache_path.stat().st_size < 1000:
            raise HTTPException(
                status_code=500,
                detail=f"fMP4 pipe transcode failed (rc={proc.returncode}): {stderr.decode(errors='replace')[:300]}"
            )
        output_size = cache_path.stat().st_size
        logger.info(
            f"[audio] Transcoded {video_id} → {output_size} bytes (fMP4) "
            f"in {pipe_seconds:.1f}s"
        )
    except HTTPException:
        raise
    except Exception:
        # Clean up partial file on any failure so the next
        # attempt can start fresh.
        if cache_path.exists():
            try:
                cache_path.unlink()
            except OSError:
                pass
        raise


async def _prefetch_worker(video_id: str, user_id: Optional[str] = None):
    """
    Background worker: warm the stream URL cache AND pre-transcode
    the audio so the user's eventual /audio call is instant.

    S17-H / S17-PLAY (Fix 3B, 2026-07-29): refactored to use
    _transcode_to_cache directly (no more internal HTTP call +
    minted-token hack). Now takes user_id as a parameter so we
    know which user the prefetch was for (used for logging; the
    transcode itself doesn't need the user_id).

    The earlier "find first user in /data/users and mint a token"
    pattern was a workaround because the worker didn't have the
    request context. Now that prefetch_stream() passes the user_id
    in, the worker can just call _transcode_to_cache which
    doesn't need auth at all (it writes to the same cache_path
    that /audio reads from, and /audio is the one that enforces
    auth on the read side).
    """
    try:
        # 1. Make sure the stream URL cache is populated (URLs
        # signed for the next 3.5h).
        cache = get_cache()
        if not cache.get(video_id):
            async with ytmusic_lock:
                client = get_client()
                stream_data = client.get_stream_url(video_id)
            if stream_data and stream_data.get("audio_formats"):
                cache.set(video_id, stream_data)
                logger.info(f"Prefetch cached stream: {video_id} (user={user_id or 'unknown'})")
            else:
                logger.warning(f"Prefetch found no audio formats: {video_id}")
                return

        # 2. Pre-transcode the audio. _transcode_to_cache handles
        # the global semaphore + per-videoId lock; this worker
        # just blocks until the transcode is done. If the user's
        # /audio call arrives first, it will do the transcode
        # and this worker will see the cache hit and return early.
        stream_data = cache.get(video_id)
        if not stream_data:
            return
        webm = [f for f in stream_data['audio_formats'] if f.get('mime_type') == 'webm']
        if not webm:
            return
        webm.sort(key=lambda f: f.get('bitrate', 0))
        yt_url = webm[0]['url']

        await _transcode_to_cache(video_id, yt_url)
        cache_path = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache') / f"{video_id}.m4a"
        if cache_path.exists():
            logger.info(f"Prefetch transcoded: {video_id} ({cache_path.stat().st_size} bytes, user={user_id or 'unknown'})")
    except Exception as e:
        logger.error(f"Prefetch failed: {video_id}: {e}", exc_info=True)


# Download endpoint
@app.post("/download", response_model=DownloadResponse)
@limiter.limit("15/minute")
async def download_track(download_req: DownloadRequest, request: Request, user: dict = Depends(require_session_user),):
    """
    Download and convert track to local M4A file.
    Works in both authenticated and guest mode.
    """
    try:
        extractor = get_extractor()

        metadata = {
            'title': download_req.title,
            'artists': download_req.artists,
            'album': download_req.album,
            'thumbnail': download_req.thumbnail
        }

        loop = asyncio.get_event_loop()
        result_path = await loop.run_in_executor(
            None,
            extractor.download_and_convert,
            download_req.video_id,
            metadata
        )

        if not result_path:
            raise HTTPException(status_code=500, detail="Download or conversion failed")

        # Write sidecar .id file so waveform endpoint can find this track by video_id
        id_file = result_path.with_suffix('.id')
        id_file.write_text(download_req.video_id)

        return DownloadResponse(
            status="completed",
            filePath=str(result_path)
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"download_track failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Download failed: {str(e)}")


# Library listing
@app.get("/library")
@limiter.limit("15/minute")
async def list_library(request: Request, user: dict = Depends(require_session_user),):
    """
    List all downloaded tracks in local library.
    Returns wrapped in {tracks: [...]} for iOS compatibility.
    """
    try:
        extractor = get_extractor()
        tracks = extractor.list_library()
        # Convert snake_case to camelCase for iOS
        camel_tracks = []
        for track in tracks:
            camel_tracks.append({
                "id": str(hash(track["path"])),
                "filename": track["filename"],
                "path": track["path"],
                "size": track["size"],
                "sizeHuman": track["size_human"],
                "modified": track["modified"]
            })
        return {"tracks": camel_tracks}
    except Exception as e:
        logger.error(f"list_library failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Library listing failed: {str(e)}")


# Library delete endpoint
@app.delete("/library/{filename}")
@limiter.limit("15/minute")
async def delete_library_file(filename: str, request: Request, user: dict = Depends(require_session_user),):
    """
    Delete a file from the library.
    """
    try:
        extractor = get_extractor()
        # URL decode the filename
        import urllib.parse
        decoded_filename = urllib.parse.unquote(filename)

        if extractor.delete_file(decoded_filename):
            return {"status": "deleted", "filename": decoded_filename}
        else:
            raise HTTPException(status_code=404, detail="File not found")
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"delete_library_file failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Delete failed: {str(e)}")


# Waveform endpoint
@app.get("/waveform/{video_id}")
@limiter.limit("15/minute")
async def get_waveform(video_id: str, request: Request, user: dict = Depends(require_session_user),):
    """
    Return pre-computed waveform peaks (200 normalized floats) for a video ID.
    Checks a disk cache first, then generates from a downloaded M4A file.
    Returns 404 if no downloaded file is available (iOS will use pseudo-waveform fallback).
    """
    import json as _json

    try:
        extractor = get_extractor()
        cache_dir = extractor.output_dir / ".waveform_cache"
        cache_dir.mkdir(exist_ok=True)
        cache_file = cache_dir / f"{video_id}.json"

        # Serve from cache if available
        if cache_file.exists():
            data = _json.loads(cache_file.read_text())
            return data

        # Find downloaded file for this video_id using sidecar .id file
        target_path = None
        for m4a in extractor.output_dir.glob("*.m4a"):
            id_file = m4a.with_suffix('.id')
            if id_file.exists() and id_file.read_text().strip() == video_id:
                target_path = m4a
                break

        if not target_path:
            raise HTTPException(
                status_code=404,
                detail="No downloaded file found for this video_id"
            )

        # Generate waveform in thread pool to avoid blocking the event loop
        loop = asyncio.get_event_loop()
        peaks = await loop.run_in_executor(
            None, lambda: extractor.generate_waveform(target_path, peaks=200)
        )
        if not peaks:
            raise HTTPException(status_code=500, detail="Waveform generation failed")

        result = {"videoId": video_id, "peaks": peaks}
        # Atomic write: write to temp file then rename to avoid race conditions
        import tempfile
        tmp_fd, tmp_path = tempfile.mkstemp(dir=str(cache_dir), suffix=".json.tmp")
        try:
            import os
            os.write(tmp_fd, _json.dumps(result).encode())
            os.close(tmp_fd)
            os.rename(tmp_path, str(cache_file))
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
        cleanup_waveform_cache(str(cache_dir))
        return result

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"get_waveform failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Waveform error: {str(e)}")


# Local file streaming
@app.get("/local-play/{filename}")
@limiter.limit("15/minute")
async def local_play(filename: str, request: Request, user: dict = Depends(require_session_user),):
    """
    Stream a local M4A file.
    Supports HTTP range requests for seeking.
    """
    try:
        extractor = get_extractor()
        file_path = extractor.output_dir / filename

        # Path traversal protection
        try:
            file_path.resolve().relative_to(extractor.output_dir.resolve())
        except ValueError:
            raise HTTPException(status_code=403, detail="Access denied")

        if not file_path.exists():
            raise HTTPException(status_code=404, detail="File not found")

        if not file_path.suffix == '.m4a':
            raise HTTPException(status_code=400, detail="Invalid file type")

        return FileResponse(
            path=file_path,
            media_type="audio/mp4",
            filename=filename
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"local_play failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"File serving failed: {str(e)}")


# Thumbnail proxy
@app.get("/thumbnail")
@limiter.limit("30/minute")
async def proxy_thumbnail(url: str, request: Request, user: dict = Depends(require_session_user),):
    """Proxy thumbnail image. Only allows YouTube thumbnail domains."""
    try:
        from urllib.parse import urlparse
        parsed = urlparse(url)
        allowed_hosts = {'i.ytimg.com', 'i1.ytimg.com', 'i2.ytimg.com', 'i3.ytimg.com',
                         'i4.ytimg.com', 'i9.ytimg.com', 'img.youtube.com',
                         'lh3.googleusercontent.com', 'yt3.ggpht.com', 'yt3.googleusercontent.com'}
        if parsed.hostname not in allowed_hosts:
            raise HTTPException(status_code=403, detail="Domain not allowed")

        session = get_http_session()
        response = session.get(url, timeout=(THUMBNAIL_CONNECT_TIMEOUT, THUMBNAIL_READ_TIMEOUT))
        try:
            response.raise_for_status()
            content = response.content
            content_type = response.headers.get('content-type', 'image/jpeg')
        finally:
            response.close()

        return StreamingResponse(
            content=iter([content]),
            media_type=content_type
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"proxy_thumbnail failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Thumbnail fetch failed: {str(e)}")


# Lyrics endpoint
@app.get("/lyrics/{video_id}")
@limiter.limit("15/minute")
async def get_lyrics(video_id: str, request: Request, user: dict = Depends(require_session_user),):
    """Get lyrics for a track if available."""
    try:
        client = get_client()
        async with ytmusic_lock:
            lyrics = client.get_lyrics(video_id)

        if not lyrics:
            raise HTTPException(status_code=404, detail="Lyrics not available")

        return {"lyrics": lyrics}

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"get_lyrics failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Lyrics fetch failed: {str(e)}")


# Radio/Autoplay
@app.get("/radio/{video_id}")
@limiter.limit("15/minute")
async def get_radio(video_id: str, request: Request, user: dict = Depends(require_session_user),):
    """Get radio playlist based on track."""
    try:
        client = get_client()
        async with ytmusic_lock:
            tracks = client.get_watch_playlist(video_id)
        return [TrackResponse(**track).model_dump() for track in tracks]
    except Exception as e:
        logger.error(f"get_radio failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Radio generation failed: {str(e)}")


# Authenticated-only endpoints
@app.get("/liked-songs")
@limiter.limit("15/minute")
async def get_liked_songs(request: Request, user: dict = Depends(require_session_user),):
    """
    Get user's liked songs (authenticated only).
    """
    client = get_client()
    if not client.authenticated:
        raise HTTPException(
            status_code=401,
            detail="Authentication required. Run: make auth"
        )

    try:
        async with ytmusic_lock:
            tracks = client.get_liked_songs()
        return {"tracks": tracks}
    except Exception as e:
        logger.error(f"get_liked_songs failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Failed to get liked songs: {str(e)}")


@app.get("/playlists")
@limiter.limit("15/minute")
async def get_playlists(request: Request, user: dict = Depends(require_session_user),):
    """
    Get user's playlists (authenticated only).
    """
    client = get_client()
    if not client.authenticated:
        raise HTTPException(
            status_code=401,
            detail="Authentication required. Run: make auth"
        )

    try:
        async with ytmusic_lock:
            playlists = client.get_library_playlists()
        return {"playlists": playlists}
    except Exception as e:
        logger.error(f"get_playlists failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Failed to get playlists: {str(e)}")


# Charts / Trending
@app.get("/charts")
@limiter.limit("5/minute")
async def get_charts(request: Request, user: dict = Depends(require_session_user),):
    """Get trending charts from YouTube Music."""
    cached = trending_cache.get("charts")
    if cached is not None:
        return cached
    try:
        client = get_client()
        tracks = []

        try:
            async with ytmusic_lock:
                charts = client.yt.get_charts(country=YOUTUBE_COUNTRY)

            # Parse trending songs if available
            if charts and 'songs' in charts:
                for item in charts['songs'].get('items', []):
                    track = {
                        'videoId': item.get('videoId'),
                        'title': item.get('title', 'Unknown Title'),
                        'artists': [a.get('name', 'Unknown') for a in item.get('artists', [])],
                        'album': item.get('album', {}).get('name', 'Unknown Album'),
                        'durationSeconds': item.get('duration_seconds', 0),
                        'thumbnails': item.get('thumbnails', []),
                        'isExplicit': item.get('isExplicit', False),
                        'videoType': item.get('videoType', 'MUSIC')
                    }
                    tracks.append(track)
        except Exception as charts_error:
            logger.debug(f"Charts API not available (guest mode): {charts_error}")

        # Fallback: Use search for trending content if API returns empty
        if not tracks:
            logger.info("Charts API returned empty, using search fallback")
            fallback_queries = [
                "trending music",
                "viral songs",
                "popular now",
                "top hits"
            ]
            import random
            query = random.choice(fallback_queries)
            # Use search_tracks which returns properly formatted data
            async with ytmusic_lock:
                tracks = client.search_tracks(query, limit=20)

        result = {"tracks": [TrackResponse(**track).model_dump() for track in tracks[:20]]}
        trending_cache.set("charts", result)
        return result
    except Exception as e:
        logger.error(f"Charts fetch failed: {e}")
        return {"tracks": []}


@app.get("/new-releases")
@limiter.limit("5/minute")
async def get_new_releases(request: Request, user: dict = Depends(require_session_user),):
    """Get new releases from YouTube Music."""
    cached = trending_cache.get("new-releases")
    if cached is not None:
        return cached
    try:
        client = get_client()
        tracks = []

        try:
            async with ytmusic_lock:
                releases = client.yt.get_new_releases(country=YOUTUBE_COUNTRY)

            if releases:
                # Parse new releases - they're albums, extract tracks
                for album in releases[:15]:  # Limit to first 15 albums
                    try:
                        album_id = album.get('browseId')
                        if album_id:
                            async with ytmusic_lock:
                                album_data = client.yt.get_album(album_id)
                            for track in album_data.get('tracks', [])[:2]:  # Top 2 tracks per album
                                track_data = {
                                    'videoId': track.get('videoId'),
                                    'title': track.get('title', 'Unknown Title'),
                                    'artists': [a.get('name', 'Unknown') for a in track.get('artists', [])],
                                    'album': album.get('title', 'Unknown Album'),
                                    'durationSeconds': track.get('duration_seconds', 0),
                                    'thumbnails': album.get('thumbnails', []),
                                    'isExplicit': track.get('isExplicit', False),
                                    'videoType': track.get('videoType', 'MUSIC')
                                }
                                tracks.append(track_data)
                    except Exception as album_error:
                        logger.debug(f"Failed to get album details: {album_error}")
                        continue
        except Exception as api_error:
            logger.debug(f"New releases API failed: {api_error}")

        # Fallback: Use search for new releases if API returns empty
        if not tracks:
            logger.info("New releases API returned empty, using search fallback")
            fallback_queries = [
                "new music releases",
                "new songs 2024",
                "latest hits",
                "just released"
            ]
            import random
            query = random.choice(fallback_queries)
            # Use search_tracks which returns properly formatted data
            async with ytmusic_lock:
                tracks = client.search_tracks(query, limit=20)

        result = {"tracks": [TrackResponse(**track).model_dump() for track in tracks[:20]]}
        trending_cache.set("new-releases", result)
        return result
    except Exception as e:
        logger.error(f"New releases fetch failed: {e}")
        return {"tracks": []}


# --- Internet Radio (RadioBrowser API) ---

RADIO_BROWSER_BASE = "https://de1.api.radio-browser.info"
RADIO_HEADERS = {"User-Agent": "PeacePlayer/1.0"}


def _format_station(s: dict) -> dict:
    return {
        "stationuuid": s.get("stationuuid", ""),
        "name": s.get("name", "Unknown Station"),
        "urlResolved": s.get("url_resolved", s.get("url", "")),
        "favicon": s.get("favicon", ""),
        "country": s.get("country", ""),
        "tags": s.get("tags", ""),
        "codec": s.get("codec", ""),
        "bitrate": s.get("bitrate", 0),
        "clickcount": s.get("clickcount", 0),
        "votes": s.get("votes", 0),
    }


@app.get("/radio-stations/search")
@limiter.limit("30/minute")
async def search_radio_stations(query: str, limit: int = 20, request: Request = None, user: dict = Depends(require_session_user),):
    """Search internet radio stations."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                f"{RADIO_BROWSER_BASE}/json/stations/search",
                params={"name": query, "limit": limit, "hidebroken": "true", "order": "clickcount", "reverse": "true"},
                headers=RADIO_HEADERS,
            )
            resp.raise_for_status()
            return [_format_station(s) for s in resp.json()]
    except httpx.HTTPStatusError as e:
        logger.error(f"RadioBrowser search HTTP error: {e}")
        raise HTTPException(status_code=e.response.status_code, detail="Radio search upstream error")
    except Exception as e:
        logger.error(f"RadioBrowser search failed: {e}")
        raise HTTPException(status_code=502, detail=f"Radio search failed: {str(e)}")


@app.get("/radio-stations/genre/{tag}")
@limiter.limit("30/minute")
async def get_radio_by_genre(tag: str, limit: int = 30, request: Request = None, user: dict = Depends(require_session_user),):
    """Get radio stations by genre tag."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                f"{RADIO_BROWSER_BASE}/json/stations/bytag/{tag}",
                params={"hidebroken": "true", "order": "clickcount", "reverse": "true", "limit": limit},
                headers=RADIO_HEADERS,
            )
            resp.raise_for_status()
            return [_format_station(s) for s in resp.json()]
    except httpx.HTTPStatusError as e:
        logger.error(f"RadioBrowser genre HTTP error: {e}")
        raise HTTPException(status_code=e.response.status_code, detail="Radio genre upstream error")
    except Exception as e:
        logger.error(f"RadioBrowser genre failed: {e}")
        raise HTTPException(status_code=502, detail=f"Radio genre fetch failed: {str(e)}")


@app.get("/radio-stations/top")
@limiter.limit("30/minute")
async def get_top_radio_stations(limit: int = 30, request: Request = None, user: dict = Depends(require_session_user),):
    """Get top radio stations by click count."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                f"{RADIO_BROWSER_BASE}/json/stations/topclick/{limit}",
                params={"hidebroken": "true"},
                headers=RADIO_HEADERS,
            )
            resp.raise_for_status()
            return [_format_station(s) for s in resp.json()]
    except httpx.HTTPStatusError as e:
        logger.error(f"RadioBrowser top HTTP error: {e}")
        raise HTTPException(status_code=e.response.status_code, detail="Radio top upstream error")
    except Exception as e:
        logger.error(f"RadioBrowser top failed: {e}")
        raise HTTPException(status_code=502, detail=f"Radio top fetch failed: {str(e)}")


@app.get("/radio-stations/trending")
@limiter.limit("30/minute")
async def get_trending_radio_stations(limit: int = 30, request: Request = None, user: dict = Depends(require_session_user),):
    """Get recently changed/trending radio stations."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                f"{RADIO_BROWSER_BASE}/json/stations/lastchange/{limit}",
                params={"hidebroken": "true"},
                headers=RADIO_HEADERS,
            )
            resp.raise_for_status()
            return [_format_station(s) for s in resp.json()]
    except httpx.HTTPStatusError as e:
        logger.error(f"RadioBrowser trending HTTP error: {e}")
        raise HTTPException(status_code=e.response.status_code, detail="Radio trending upstream error")
    except Exception as e:
        logger.error(f"RadioBrowser trending failed: {e}")
        raise HTTPException(status_code=502, detail=f"Radio trending fetch failed: {str(e)}")


@app.post("/radio-stations/{stationuuid}/click")
@limiter.limit("60/minute")
async def register_radio_click(stationuuid: str, request: Request, user: dict = Depends(require_session_user),):
    """Register a click for a radio station (updates popularity)."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                f"{RADIO_BROWSER_BASE}/json/url/{stationuuid}",
                headers=RADIO_HEADERS,
            )
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPStatusError as e:
        logger.error(f"RadioBrowser click HTTP error: {e}")
        raise HTTPException(status_code=e.response.status_code, detail="Radio click upstream error")
    except Exception as e:
        logger.error(f"RadioBrowser click failed: {e}")
        raise HTTPException(status_code=502, detail=f"Radio click failed: {str(e)}")


# --- Podcasts (iTunes API + RSS) ---

def _format_podcast(p: dict) -> dict:
    return {
        "collectionId": p.get("collectionId", 0),
        "collectionName": p.get("collectionName", "Unknown"),
        "artistName": p.get("artistName", "Unknown"),
        "artworkUrl600": p.get("artworkUrl600", p.get("artworkUrl100", "")),
        "feedUrl": p.get("feedUrl", ""),
        "genres": p.get("genres", []),
        "trackCount": p.get("trackCount", 0),
        "releaseDate": p.get("releaseDate", ""),
    }


def _parse_duration(text: str) -> int:
    """Parse podcast duration: HH:MM:SS, MM:SS, or raw seconds."""
    text = text.strip()
    if ":" in text:
        parts = text.split(":")
        try:
            if len(parts) == 3:
                return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
            elif len(parts) == 2:
                return int(parts[0]) * 60 + int(parts[1])
        except ValueError:
            return 0
    try:
        return int(text)
    except ValueError:
        return 0


@app.get("/podcasts/search")
@limiter.limit("30/minute")
async def search_podcasts(query: str, limit: int = 20, request: Request = None, user: dict = Depends(require_session_user),):
    """Search podcasts via iTunes Search API."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                "https://itunes.apple.com/search",
                params={"term": query, "media": "podcast", "limit": limit},
            )
            resp.raise_for_status()
            results = resp.json().get("results", [])
            return [_format_podcast(p) for p in results]
    except httpx.HTTPStatusError as e:
        logger.error(f"iTunes podcast search HTTP error: {e}")
        raise HTTPException(status_code=e.response.status_code, detail="Podcast search upstream error")
    except Exception as e:
        logger.error(f"Podcast search failed: {e}")
        raise HTTPException(status_code=502, detail=f"Podcast search failed: {str(e)}")


@app.get("/podcasts/episodes")
@limiter.limit("20/minute")
async def get_podcast_episodes(feedUrl: str, limit: int = 50, request: Request = None, user: dict = Depends(require_session_user),):
    """Fetch and parse podcast RSS feed for episodes."""
    try:
        async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
            resp = await client.get(feedUrl, headers={"User-Agent": "PeacePlayer/1.0"})
            resp.raise_for_status()

        root = ET.fromstring(resp.text)
        channel = root.find("channel")
        if channel is None:
            raise HTTPException(status_code=400, detail="Invalid RSS feed")

        itunes_ns = "{http://www.itunes.com/dtds/podcast-1.0.dtd}"

        show_artwork = ""
        itunes_image = channel.find(f"{itunes_ns}image")
        if itunes_image is not None:
            show_artwork = itunes_image.get("href", "")

        episodes = []
        items = channel.findall("item")
        for item in items[:limit]:
            enclosure = item.find("enclosure")
            audio_url = enclosure.get("url", "") if enclosure is not None else ""
            if not audio_url:
                continue

            duration_el = item.find(f"{itunes_ns}duration")
            duration_secs = 0
            if duration_el is not None and duration_el.text:
                duration_secs = _parse_duration(duration_el.text)

            ep_image = item.find(f"{itunes_ns}image")
            ep_artwork = ep_image.get("href", "") if ep_image is not None else show_artwork

            title_el = item.find("title")
            desc_el = item.find("description")
            pubdate_el = item.find("pubDate")
            guid_el = item.find("guid")

            episodes.append({
                "guid": guid_el.text if guid_el is not None and guid_el.text else audio_url,
                "title": title_el.text if title_el is not None and title_el.text else "Untitled",
                "description": (desc_el.text or "")[:500] if desc_el is not None else "",
                "audioUrl": audio_url,
                "durationSeconds": duration_secs,
                "pubDate": pubdate_el.text if pubdate_el is not None and pubdate_el.text else "",
                "artworkUrl": ep_artwork,
            })

        return episodes
    except HTTPException:
        raise
    except ET.ParseError as e:
        logger.error(f"RSS parse error for {feedUrl}: {e}")
        raise HTTPException(status_code=400, detail="Failed to parse RSS feed")
    except httpx.HTTPStatusError as e:
        logger.error(f"Podcast episodes HTTP error: {e}")
        raise HTTPException(status_code=e.response.status_code, detail="Podcast feed upstream error")
    except Exception as e:
        logger.error(f"Podcast episodes failed: {e}")
        raise HTTPException(status_code=502, detail=f"Podcast episodes failed: {str(e)}")


@app.get("/podcasts/top")
@limiter.limit("20/minute")
async def get_top_podcasts(genre: str = "", limit: int = 20, request: Request = None, user: dict = Depends(require_session_user),):
    """Get top podcasts, optionally filtered by genre."""
    try:
        params = {"media": "podcast", "limit": limit}
        if genre:
            params["term"] = genre
        else:
            params["term"] = "top podcasts"

        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get("https://itunes.apple.com/search", params=params)
            resp.raise_for_status()
            results = resp.json().get("results", [])
            return [_format_podcast(p) for p in results]
    except httpx.HTTPStatusError as e:
        logger.error(f"iTunes top podcasts HTTP error: {e}")
        raise HTTPException(status_code=e.response.status_code, detail="Top podcasts upstream error")
    except Exception as e:
        logger.error(f"Top podcasts failed: {e}")
        raise HTTPException(status_code=502, detail=f"Top podcasts failed: {str(e)}")


# --- Audiobooks (LibriVox + Archive.org) ---

def _format_audiobook(book: dict) -> dict:
    """Normalize a LibriVox catalog JSON book to camelCase response."""
    authors = book.get("authors", [])
    author_names = [
        f"{a.get('first_name', '')} {a.get('last_name', '')}".strip()
        for a in authors
    ]

    book_id = book.get("id", "")
    cover_url = ""
    # Try to derive an Archive.org cover from url_zip_file
    zip_url = book.get("url_zip_file", "")
    if zip_url:
        # Pattern: https://archive.org/compress/IDENTIFIER/...
        parts = zip_url.replace("https://", "").split("/")
        if len(parts) >= 3:
            identifier = parts[2]
            cover_url = f"https://archive.org/services/img/{identifier}"

    description = book.get("description", "")
    if description:
        description = re.sub(r"<[^>]+>", "", description)

    return {
        "id": book_id,
        "title": book.get("title", "Unknown"),
        "description": description,
        "authors": author_names,
        "language": book.get("language", "English"),
        "totalTime": book.get("totaltime", "0:00:00"),
        "totalTimeSecs": int(book.get("totaltimesecs", 0) or 0),
        "numSections": int(book.get("num_sections", 0) or 0),
        "rssUrl": book.get("url_rss", ""),
        "coverUrl": cover_url,
        "urlLibrivox": book.get("url_librivox", ""),
    }


@app.get("/audiobooks/top")
@limiter.limit("20/minute")
async def get_top_audiobooks(
    limit: int = 20,
    offset: int = 0,
    language: str = "English",
    request: Request = None, user: dict = Depends(require_session_user),):
    """Browse top audiobooks from the LibriVox catalog."""
    try:
        params = {"format": "json", "limit": limit, "offset": offset}
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(
                "https://librivox.org/api/feed/audiobooks",
                params=params,
                headers={"User-Agent": "PeacePlayer/1.0"},
            )
            resp.raise_for_status()
            data = resp.json()

        books = data.get("books", [])
        if language:
            books = [
                b for b in books
                if b.get("language", "").lower() == language.lower()
            ]
        return [_format_audiobook(b) for b in books]
    except httpx.HTTPStatusError as e:
        logger.error(f"LibriVox top audiobooks HTTP error: {e}")
        raise HTTPException(
            status_code=e.response.status_code,
            detail="LibriVox upstream error",
        )
    except Exception as e:
        logger.error(f"Top audiobooks failed: {e}")
        raise HTTPException(
            status_code=502, detail=f"Top audiobooks failed: {str(e)}"
        )


@app.get("/audiobooks/search")
@limiter.limit("20/minute")
async def search_audiobooks(
    query: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(20, ge=1, le=50),
    request: Request = None, user: dict = Depends(require_session_user),):
    """Search audiobooks via Archive.org's LibriVox collection."""
    try:
        params = {
            "q": f"collection:librivoxaudio AND title:{query}",
            "fl[]": ["identifier", "title", "creator", "description", "date"],
            "output": "json",
            "rows": limit,
        }
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(
                "https://archive.org/advancedsearch.php",
                params=params,
                headers={"User-Agent": "PeacePlayer/1.0"},
            )
            resp.raise_for_status()
            data = resp.json()

        docs = data.get("response", {}).get("docs", [])
        results = []
        for doc in docs:
            identifier = doc.get("identifier", "")

            raw_desc = doc.get("description", "")
            if isinstance(raw_desc, list):
                raw_desc = raw_desc[0] if raw_desc else ""
            description = re.sub(r"<[^>]+>", "", str(raw_desc))

            creators = doc.get("creator", ["Unknown"])
            if isinstance(creators, str):
                creators = [creators]

            results.append({
                "id": identifier,
                "title": doc.get("title", "Unknown"),
                "description": description,
                "authors": creators,
                "language": "English",
                "totalTime": "",
                "totalTimeSecs": 0,
                "numSections": 0,
                "rssUrl": "",
                "coverUrl": f"https://archive.org/services/img/{identifier}" if identifier else "",
                "urlLibrivox": "",
            })
        return results
    except httpx.HTTPStatusError as e:
        logger.error(f"Archive.org audiobook search HTTP error: {e}")
        raise HTTPException(
            status_code=e.response.status_code,
            detail="Archive.org upstream error",
        )
    except Exception as e:
        logger.error(f"Audiobook search failed: {e}")
        raise HTTPException(
            status_code=502, detail=f"Audiobook search failed: {str(e)}"
        )


@app.get("/audiobooks/genre/{genre}")
@limiter.limit("20/minute")
async def get_audiobooks_by_genre(
    genre: str = APIPath(..., min_length=1, max_length=100),
    limit: int = Query(20, ge=1, le=50),
    request: Request = None, user: dict = Depends(require_session_user),):
    """Browse audiobooks by genre from the LibriVox catalog."""
    try:
        params = {"format": "json", "genre": genre, "limit": limit}
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(
                "https://librivox.org/api/feed/audiobooks",
                params=params,
                headers={"User-Agent": "PeacePlayer/1.0"},
            )
            resp.raise_for_status()
            data = resp.json()

        books = data.get("books", [])
        return [_format_audiobook(b) for b in books]
    except httpx.HTTPStatusError as e:
        logger.error(f"LibriVox genre audiobooks HTTP error: {e}")
        raise HTTPException(
            status_code=e.response.status_code,
            detail="LibriVox upstream error",
        )
    except Exception as e:
        logger.error(f"Genre audiobooks failed: {e}")
        raise HTTPException(
            status_code=502, detail=f"Genre audiobooks failed: {str(e)}"
        )


@app.get("/audiobooks/{book_id}/chapters")
@limiter.limit("20/minute")
async def get_audiobook_chapters(
    book_id: str,
    limit: int = Query(200, ge=1, le=500),
    rssUrl: str = None,
    request: Request = None, user: dict = Depends(require_session_user),):
    """Fetch chapters for an audiobook from its LibriVox RSS feed or Archive.org metadata."""
    try:
        # SSRF protection: validate rssUrl domain if provided
        if rssUrl:
            from urllib.parse import urlparse
            parsed = urlparse(rssUrl)
            allowed_domains = {"librivox.org", "www.librivox.org", "archive.org", "www.archive.org"}
            if parsed.netloc not in allowed_domains:
                raise HTTPException(status_code=400, detail="Invalid RSS URL domain")
            feed_url = rssUrl
        else:
            feed_url = None

        # Archive.org fallback for non-numeric book IDs (e.g. "count_monte_cristo_0711_librivox")
        if not book_id.isdigit() and not rssUrl:
            try:
                async with httpx.AsyncClient(timeout=20) as client:
                    meta_resp = await client.get(f"https://archive.org/metadata/{book_id}/files")
                    meta_resp.raise_for_status()
                    files = meta_resp.json().get("result", [])

                    # Prefer higher quality: VBR > 128Kbps, skip 64Kbps duplicates
                    all_mp3 = [
                        f for f in files
                        if f.get("name", "").endswith(".mp3")
                    ]
                    # Group by base name (without _64kb suffix)
                    seen_bases = set()
                    audio_files = []
                    # Sort so VBR/128k come before 64kb variants
                    all_mp3.sort(key=lambda f: (f.get("name", ""), "64kb" in f.get("name", "")))
                    for f in all_mp3:
                        name = f.get("name", "")
                        base = name.replace("_64kb", "").replace("_128kb", "")
                        if base not in seen_bases:
                            seen_bases.add(base)
                            audio_files.append(f)
                    audio_files.sort(key=lambda f: f.get("name", ""))

                    chapters = []
                    for i, af in enumerate(audio_files):
                        filename = af.get("name", "")
                        title = af.get("title", filename.replace(".mp3", "").replace("_", " "))
                        duration_str = af.get("length", "0")
                        try:
                            duration = int(float(duration_str))
                        except (ValueError, TypeError):
                            duration = 0

                        chapters.append({
                            "guid": f"{book_id}_{i}",
                            "title": title,
                            "chapterNumber": i + 1,
                            "audioUrl": f"https://archive.org/download/{book_id}/{filename}",
                            "durationSeconds": duration,
                        })

                    return {"chapters": chapters, "coverUrl": f"https://archive.org/services/img/{book_id}"}
            except Exception as e:
                logger.warning(f"Archive.org metadata fetch failed for {book_id}, falling back to RSS: {e}")
                feed_url = f"https://librivox.org/rss/{book_id}"

        if feed_url is None:
            feed_url = f"https://librivox.org/rss/{book_id}"

        async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
            resp = await client.get(
                feed_url, headers={"User-Agent": "PeacePlayer/1.0"}
            )
            resp.raise_for_status()

        root = ET.fromstring(resp.text)
        channel = root.find("channel")
        if channel is None:
            raise HTTPException(status_code=400, detail="Invalid RSS feed")

        itunes_ns = "{http://www.itunes.com/dtds/podcast-1.0.dtd}"

        cover_url = ""
        itunes_image = channel.find(f"{itunes_ns}image")
        if itunes_image is not None:
            cover_url = itunes_image.get("href", "")

        chapters = []
        items = channel.findall("item")
        for item in items[:limit]:
            enclosure = item.find("enclosure")
            audio_url = enclosure.get("url", "") if enclosure is not None else ""
            if not audio_url:
                continue

            duration_el = item.find(f"{itunes_ns}duration")
            duration_secs = 0
            if duration_el is not None and duration_el.text:
                duration_secs = _parse_duration(duration_el.text)

            episode_el = item.find(f"{itunes_ns}episode")
            chapter_number = 0
            if episode_el is not None and episode_el.text:
                try:
                    chapter_number = int(episode_el.text)
                except ValueError:
                    pass

            title_el = item.find("title")
            guid_el = item.find("guid")

            chapters.append({
                "guid": guid_el.text if guid_el is not None and guid_el.text else audio_url,
                "title": title_el.text if title_el is not None and title_el.text else "Untitled",
                "chapterNumber": chapter_number,
                "audioUrl": audio_url,
                "durationSeconds": duration_secs,
            })

        return {"coverUrl": cover_url, "chapters": chapters}
    except HTTPException:
        raise
    except ET.ParseError as e:
        logger.error(f"Audiobook RSS parse error for {book_id}: {e}")
        raise HTTPException(status_code=400, detail="Failed to parse audiobook RSS feed")
    except httpx.HTTPStatusError as e:
        logger.error(f"Audiobook chapters HTTP error: {e}")
        raise HTTPException(
            status_code=e.response.status_code,
            detail="Audiobook feed upstream error",
        )
    except Exception as e:
        logger.error(f"Audiobook chapters failed: {e}")
        raise HTTPException(
            status_code=502, detail=f"Audiobook chapters failed: {str(e)}"
        )


# --- Guitar Chords ---
@app.get("/chords")
@limiter.limit("30/minute")
async def get_chords(request: Request, title: str = Query(...), artist: str = Query(""), user: dict = Depends(require_session_user),):
    """Search Songsterr for guitar chords/tabs matching a song title and artist."""
    query = f"{title} {artist}".strip()
    try:
        resp = _requests.get(
            "https://www.songsterr.com/api/songs",
            params={"pattern": query},
            timeout=6,
            headers={"User-Agent": "Mozilla/5.0"}
        )
        resp.raise_for_status()
        songs = resp.json()
    except Exception as e:
        logging.warning(f"Songsterr search failed: {e}")
        raise HTTPException(status_code=502, detail="Chord search service unavailable")

    if not songs:
        raise HTTPException(status_code=404, detail="No chords found for this song")

    top = songs[0]
    song_id = top.get("songId", 0)
    song_title = top.get("title", title)
    song_artist = top.get("artist", artist)

    def slugify(text: str) -> str:
        text = text.lower().strip()
        text = re.sub(r"[^\w\s-]", "", text)
        return re.sub(r"[\s_]+", "-", text)

    artist_slug = slugify(song_artist)
    title_slug = slugify(song_title)

    if artist_slug and title_slug:
        tab_url = f"https://www.songsterr.com/a/wsa/{artist_slug}-{title_slug}-tab-s{song_id}"
    else:
        tab_url = f"https://www.songsterr.com/?pattern={query.replace(' ', '+')}"

    has_chords = top.get("hasChords", False)
    has_player = top.get("hasPlayer", False)

    return {
        "found": True,
        "title": song_title,
        "artist": song_artist,
        "url": tab_url,
        "songsterrId": song_id,
        "hasChords": has_chords,
        "hasPlayer": has_player,
    }


# --- Health check ---
@app.get("/health")
@limiter.limit("15/minute")
async def health_check(request: Request):
    """Health check endpoint with YouTube connectivity test."""
    uptime = (datetime.datetime.now() - _server_start_time).total_seconds()
    youtube_ok = False
    try:
        client = get_client()
        async with ytmusic_lock:
            client.yt.get_home()
        youtube_ok = True
    except Exception:
        pass
    return {
        "status": "ok",
        "youtube": youtube_ok,
        "uptime_seconds": int(uptime),
        "cache_sizes": {
            "search": len(search_cache._cache),
            "trending": len(trending_cache._cache),
        }
    }


# --- Waveform cache cleanup ---
def cleanup_waveform_cache(cache_dir=None):
    """Evict oldest waveform cache files if total size exceeds limit."""
    try:
        if cache_dir is None:
            extractor = get_extractor()
            cache_dir = str(extractor.output_dir / ".waveform_cache")
        if not os.path.isdir(cache_dir):
            return
        files = _glob.glob(os.path.join(cache_dir, "*.json"))
        if not files:
            return
        total_size = sum(os.path.getsize(f) for f in files)
        max_bytes = MAX_WAVEFORM_CACHE_MB * 1024 * 1024
        if total_size > max_bytes:
            files.sort(key=os.path.getmtime)
            target = int(max_bytes * 0.8)
            while total_size > target and files:
                f = files.pop(0)
                fsize = os.path.getsize(f)
                os.remove(f)
                total_size -= fsize
                logger.info(f"Evicted waveform cache: {os.path.basename(f)} ({fsize} bytes)")
    except Exception as e:
        logger.warning(f"Waveform cache cleanup failed: {e}")


@app.on_event("startup")
async def startup_event():
    """Run startup tasks."""
    cleanup_waveform_cache()
    # S17 (CV-3): confirm at startup that the JWT secret is
    # configured. We don't log the secret itself (it's a
    # secret) but we log its length so an operator can spot a
    # blank or short value at a glance. apple_auth.py
    # already raises on import if the env var is missing —
    # this is a belt-and-braces confirmation that we're using
    # the configured secret and not a fallback.
    secret = os.environ.get("PEACEPLAYER_JWT_SECRET", "")
    if secret:
        logger.info(
            f"JWT secret loaded from env ({len(secret)} chars). "
            "Session JWTs use this key."
        )
    else:
        # Should be unreachable — apple_auth.py raises on
        # import if the var is missing.
        logger.warning("PEACEPLAYER_JWT_SECRET is empty!")
    logger.info("Server started")

    # S17-H / S17-PLAY (Fix 5, 2026-07-29): kick off the
    # pre-warm background task. It runs every hour, pre-warming
    # the audio cache for the user's most-recently-played tracks
    # so the first play after a cold start is instant. This is
    # the server-side companion to Fix 3A's play-time prefetch —
    # pre-warm handles "I haven't opened the app in a while",
    # prefetch handles "I just tapped a track".
    #
    # Implementation note: we use a daemon Thread instead of
    # asyncio.create_task. The deprecated @app.on_event("startup")
    # pattern doesn't seem to play well with task creation here —
    # the server shuts down within milliseconds of calling
    # asyncio.create_task. A daemon thread is decoupled from the
    # event loop and runs cleanly in the background. The thread
    # needs its own event loop to call async helpers; use
    # asyncio.new_event_loop() + loop.run_until_complete().
    if PREWARM_ENABLED:
        import threading
        t = threading.Thread(target=_prewarm_thread_main, daemon=True, name="prewarm")
        t.start()
        logger.info(f"Pre-warm thread started (interval={PREWARM_INTERVAL}s, top_n={PREWARM_TOP_N})")

    # S17-H / HLS (Fix 4 Phase 4, 2026-07-30): kick off the
    # HLS directory cleanup task. HLS dirs can grow — each
    # cold play creates a new dir with ~140 segments. We
    # remove dirs where the corresponding audio cache m4a
    # already exists (meaning the user has moved on to warm
    # plays, no need for the HLS segments anymore) AND
    # the dir is older than HLS_CLEANUP_AGE_S.
    if HLS_CLEANUP_ENABLED:
        import threading
        t = threading.Thread(target=_hls_cleanup_thread_main, daemon=True, name="hls-cleanup")
        t.start()
        logger.info(f"HLS cleanup thread started (interval={HLS_CLEANUP_INTERVAL_S}s, age_threshold={HLS_CLEANUP_AGE_S}s)")


# S17-H / S17-PLAY (Fix 5): pre-warm configuration. Defaults
# chosen to be safe for a single-user Tailscale backend — 1
# concurrent transcode, top-10 tracks per user, hourly cycle.
# Override via env vars if you have more headroom.
PREWARM_ENABLED = os.environ.get("PREWARM_ENABLED", "true").lower() in ("1", "true", "yes")
PREWARM_INTERVAL = int(os.environ.get("PREWARM_INTERVAL", "3600"))   # 1 hour
PREWARM_TOP_N = int(os.environ.get("PREWARM_TOP_N", "10"))           # top 10 per user
PREWARM_USER_LOOKBACK_DAYS = int(os.environ.get("PREWARM_USER_LOOKBACK_DAYS", "7"))


def _prewarm_thread_main():
    """
    S17-H / S17-PLAY (Fix 5): entry point for the pre-warm daemon
    thread. Sets up a private event loop and runs the async loop
    on it. Daemon=True means the thread is killed when the main
    process exits.
    """
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(_prewarm_loop())
    finally:
        loop.close()


# ====================================================================
# S17-H / S17-PLAY — HLS streaming (Fix 4 Phase 3, 2026-07-30)
# ====================================================================
#
# When a user plays a track that's not in the audio cache, instead
# of waiting for the entire transcode to complete before serving
# the file, we serve it as an HLS (HTTP Live Streaming) playlist
# with fMP4 segments. ffmpeg's HLS muxer writes each segment as
# soon as it's full (per-segment moov atom, ~2s of audio each), so
# AVPlayer can start playing within ~3s of the request — vs ~12s
# for the full transcode on a short clip and ~50s on a 3-5 min
# track.
#
# Auth: every segment URL has the JWT in the query string (same
# pattern as /audio/{video_id}.m4a?token=...). The m3u8 endpoint
# reads the token from its own request and rewrites the segment
# URLs to include it.
#
# Concurrency: same per-videoId lock + global semaphore as the
# existing transcode pipeline. Multiple iOS requests for the same
# cold track share one HLS transcode.
#
# File layout:
#   data/hls/{video_id}/playlist.m3u8   <- written by ffmpeg
#   data/hls/{video_id}/seg_000.m4s     <- written by ffmpeg
#   data/hls/{video_id}/seg_001.m4s     <- written by ffmpeg
#   ...
#
# The m3u8 served to AVPlayer is GENERATED (not the raw ffmpeg
# output) so we can inject the auth token into each segment URL.

HLS_DIR = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/hls')
HLS_SEGMENT_TIME = 2  # seconds per segment — 2s gives ~3s TTFB
# S17-H / HLS (Fix 4 Phase 3, 2026-07-30): bumped from 10s
# after first device test. 10s wasn't enough when (a) the
# global transcode semaphore is busy (cap=2), or (b) the
# YouTube stream URL fetch takes a while. The iOS user gets
# a "preparing audio" message during this wait (Fix 6's
# .transcoding state), so longer is OK as long as it
# eventually succeeds.
HLS_MAX_WAIT_FOR_FIRST_SEGMENT_S = 30.0  # max wait for the first segment before 504


async def _get_or_fetch_stream_url(video_id: str) -> Optional[str]:
    """
    Helper: get the YouTube stream URL for a videoId. Reuses the
    existing in-memory cache (stream_cache, separate from the
    audio cache). Returns the smallest webm (Opus) URL or None.
    Same logic as audio_stream:865-910, factored out so /play
    and /audio don't duplicate it.
    """
    try:
        cache = get_cache()
        stream_data = cache.get(video_id)
        if not stream_data:
            async with ytmusic_lock:
                client = get_client()
                stream_data = client.get_stream_url(video_id)
            if not stream_data or not stream_data.get('audio_formats'):
                return None
            cache.set(video_id, stream_data)

        formats = stream_data['audio_formats']
        webm = [f for f in formats if f.get('mime_type') == 'webm']
        if not webm:
            return None
        webm.sort(key=lambda f: f.get('bitrate', 0))
        return webm[0]['url']
    except Exception as e:
        logger.error(f"_get_or_fetch_stream_url failed for {video_id}: {e}", exc_info=True)
        return None


def _hls_dir_for(video_id: str) -> Path:
    return HLS_DIR / video_id


def _hls_first_segment_path(video_id: str) -> Path:
    return HLS_DIR / video_id / "seg_000.m4s"


def _hls_playlist_path(video_id: str) -> Path:
    return HLS_DIR / video_id / "playlist.m3u8"


async def _hls_transcode_worker(video_id: str, yt_url: str, done_event: asyncio.Event) -> None:
    """
    Background worker: run yt-dlp → ffmpeg HLS pipeline writing
    segments to data/hls/{video_id}/.

    Unlike the existing _do_transcode_pipeline (which writes a
    single .m4a file), this writes an m3u8 + .m4s segments as
    they're produced. ffmpeg's HLS muxer flushes each segment
    to disk as soon as it's full (per-segment moov atom), so the
    files appear progressively — the first segment is ready
    in ~3s for typical inputs.

    Holds the per-videoId lock for the duration of the transcode
    (acquired in the endpoint, not here) so concurrent requests
    share the same in-progress segments.

    Respects the global _transcode_semaphore (cap=2) via the
    ffmpeg subprocess. HLS isn't in the critical path of the
    warm-play path, so this doesn't compete with regular
    transcode requests for the semaphore — but if a burst of
    cold plays happens, the cap still protects the backend.

    On successful completion:
      - sets done_event (the endpoint uses this to know when
        the transcode is complete; it can then add the
        #EXT-X-ENDLIST tag to the m3u8 if needed)
      - schedules _hls_concat_to_m4a as a follow-up so future
        warm plays use the fast /audio path
      - unregisters the job from _hls_active_jobs (allows new
        jobs to be started for the same videoId, e.g., after
        a token expiry that needs a fresh start)
    """
    hls_dir = _hls_dir_for(video_id)
    hls_dir.mkdir(parents=True, exist_ok=True)

    # Clean up any stale state from a previous attempt. S17-H /
    # HLS-LATENCY (2026-08-06): previously we only cleaned
    # seg_*.m4s, leaving a stale playlist.m3u8 + init.mp4 on
    # disk if the previous worker died mid-run. AVPlayer would
    # then parse the stale m3u8 (with EXT-X-ENDLIST and dead
    # segment references) and enter an infinite 503 retry loop.
    # Wipe the whole HLS dir contents so the new transcode
    # starts from a clean slate.
    for f in hls_dir.glob('*'):
        if f.is_file():
            try:
                f.unlink()
            except OSError:
                pass

    seg_pattern = hls_dir / "seg_%03d.m4s"

    # S17-H / HLS-LATENCY (2026-08-06): retry the transcode with
    # alternative format selectors on failure. The first attempt
    # uses the optimal format (smallest webm/Opus, fastest to
    # transcode). The retry tries a more permissive format that
    # accepts DASH-manifest m4a or higher-bitrate webm — useful
    # when YouTube's n-challenge or region restrictions reject
    # the preferred format. Without retry, a single transient
    # YouTube error would kill the entire transcode.
    #
    # Each entry is a yt-dlp format selector. The ffmpeg pipe is
    # the same for all of them.
    format_attempts = [
        # 1. Optimal: smallest webm/Opus (fastest to transcode)
        "worstaudio[ext=webm]/worstaudio/bestaudio[ext=webm]/bestaudio/best",
        # 2. Fallback: any audio, no format constraints. May be
        # DASH m4a which we'd have to remux, but ffmpeg handles
        # both webm/Opus and m4a/AAC transparently.
        "bestaudio/best",
    ]

    t0 = time.monotonic()
    transcode_ok = False
    last_stderr = ""
    last_format = None
    try:
        # Respect the global transcode semaphore. We acquire it
        # INSIDE the per-videoId lock (which the endpoint holds
        # before calling us) so the lock order is consistent:
        # always per-videoId first, then global.
        async with _transcode_semaphore:
            for attempt_idx, fmt in enumerate(format_attempts):
                pipe_cmd = (
                    f'{shlex.quote(YTDLP_BIN)} '
                    f'--js-runtimes deno:{shlex.quote(DENO_BIN)} '
                    f'-f {shlex.quote(fmt)} '
                    f'-o - --no-playlist --no-part --no-progress --quiet '
                    f'--remote-components ejs:github {shlex.quote(yt_url)} '
                    f'| {shlex.quote(FFMPEG_BIN)} -y -loglevel error -i pipe:0 '
                    f'-c:a aac -b:a 128k '
                    f'-f hls '
                    f'-hls_time {HLS_SEGMENT_TIME} '
                    f'-hls_playlist_type event '
                    f'-hls_segment_type fmp4 '
                    f'-hls_segment_filename {shlex.quote(str(seg_pattern))} '
                    f'{shlex.quote(str(hls_dir / "playlist.m3u8"))}'
                )
                last_format = fmt
                t_attempt = time.monotonic()
                proc = await asyncio.create_subprocess_shell(
                    pipe_cmd,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE,
                )
                _, stderr = await proc.communicate()
                attempt_seconds = time.monotonic() - t_attempt

                if proc.returncode == 0:
                    # Success — clear any partial files the failed
                    # previous attempt(s) might have left, count
                    # segments, and break.
                    num_segs = len(list(hls_dir.glob('seg_*.m4s')))
                    logger.info(
                        f"[hls] Transcoded {video_id} → {num_segs} segments "
                        f"in {attempt_seconds:.1f}s (attempt {attempt_idx + 1}, fmt={fmt!r})"
                    )
                    transcode_ok = True
                    break

                # Failure — log and try the next format.
                full_stderr = stderr.decode(errors='replace')
                last_stderr = full_stderr
                logger.warning(
                    f"[hls] ffmpeg failed for {video_id} (attempt {attempt_idx + 1}, "
                    f"rc={proc.returncode}, fmt={fmt!r}) in {attempt_seconds:.1f}s — "
                    f"will retry with next format"
                )
                logger.debug(
                    f"[hls] attempt {attempt_idx + 1} stderr for {video_id}:\n"
                    f"  command: {pipe_cmd}\n"
                    f"  stderr: {full_stderr[:1000]}"
                )
                # Clean partial output of this failed attempt so
                # the next attempt starts clean.
                for f in hls_dir.glob('*'):
                    if f.is_file():
                        try:
                            f.unlink()
                        except OSError:
                            pass

        pipe_seconds = time.monotonic() - t0
        if not transcode_ok:
            # Both attempts failed. Log the last failure and let
            # the finally clause clean up + unregister.
            logger.error(
                f"[hls] all format attempts failed for {video_id} (last fmt={last_format!r})\n"
                f"  last stderr: {last_stderr[:1000]}"
            )
    except Exception as e:
        logger.error(f"[hls] _hls_transcode_worker failed for {video_id}: {e}", exc_info=True)
    finally:
        # Always set done_event + unregister the job, regardless
        # of success/failure. Without unregistering on failure,
        # the dead job entry stays in _hls_active_jobs and
        # /play/playlist.m3u8 keeps returning the stale m3u8 to
        # every subsequent request — AVPlayer then enters an
        # infinite 503 retry loop on the missing segments
        # (observed: "Coming Back to Life" 2sHZ4ny_SxU hung
        # the iOS app for >10s on 21:29 AEST).
        done_event.set()
        _hls_unregister_job(video_id)
        if transcode_ok:
            # Schedule the concat-to-cache as a follow-up.
            asyncio.create_task(_hls_concat_and_cleanup(video_id))
        else:
            # Clean up partial HLS dir so the next /play attempt
            # starts a fresh transcode from scratch (the new
            # worker's stale-segment cleanup at line 2589 only
            # deletes seg_*.m4s, not the partial m3u8/init.mp4).
            try:
                for f in hls_dir.glob('*'):
                    if f.is_file():
                        f.unlink()
                # Leave the dir itself; the new worker will
                # recreate the files as it writes.
            except OSError as e:
                logger.warning(f"[hls] failed to clean partial dir for {video_id}: {e}")


async def _hls_wait_for_first_segment(video_id: str, timeout_s: float) -> bool:
    """
    Poll for the first segment to appear. Returns True on success,
    False on timeout. Used by the /play/playlist.m3u8 endpoint
    to know when it's safe to return the m3u8.

    S17-H / HLS (Fix 4 Phase 3, 2026-07-30): also check for
    #EXT-X-ENDLIST in the playlist. If the transcode completed
    super-fast (very short audio), the playlist will have
    ENDLIST but no segments. In that case, return False —
    there's nothing to play. (Edge case, very rare.)
    """
    first = _hls_first_segment_path(video_id)
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if first.exists() and first.stat().st_size > 0:
            return True
        # Check if the transcode completed but produced no
        # segments (very short input). In that case, give up
        # early instead of waiting the full timeout.
        m3u8 = _hls_playlist_path(video_id)
        if m3u8.exists():
            try:
                with open(m3u8, 'r') as f:
                    if '#EXT-X-ENDLIST' in f.read():
                        # Transcode is done. If we don't have
                        # the first segment, the input was too
                        # short to produce one. Fail.
                        return False
            except OSError:
                pass
        await asyncio.sleep(0.1)
    return False


# Per-videoId status tracking for the HLS pipeline. The endpoint
# uses this to know whether a transcode is already running for
# the same videoId (so concurrent requests share the segments).
_hls_active_jobs: dict = {}  # video_id -> {"event": asyncio.Event, "dir": Path, "started_at": float}


def _hls_status(video_id: str) -> Optional[dict]:
    """Return the active HLS job for this videoId, or None."""
    return _hls_active_jobs.get(video_id)


def _hls_register_job(video_id: str, event: asyncio.Event, dir_path: Path) -> None:
    _hls_active_jobs[video_id] = {
        "event": event,
        "dir": dir_path,
        "started_at": time.monotonic(),
    }


def _hls_unregister_job(video_id: str) -> None:
    _hls_active_jobs.pop(video_id, None)


@app.api_route("/play/{video_id}/playlist.m3u8", methods=["GET", "HEAD"])
@limiter.limit("60/minute")
async def play_hls_playlist(video_id: str, request: Request):
    """
    S17-H / S17-PLAY (Fix 4 Phase 3, 2026-07-30): HLS streaming
    endpoint. Returns an m3u8 playlist for AVPlayer to consume.

    Flow:
      1. Auth check (inline, like /audio — accepts Bearer header
         OR ?token= query param, since AVPlayer can't add headers).
      2. If the audio cache has a .m4a (warm path), 302 redirect
         to /audio/{videoId}.m4a?token=... — the existing fast
         path stays unchanged for warm plays.
      3. Otherwise, start (or join) an HLS transcode in the
         background. Wait up to HLS_MAX_WAIT_FOR_FIRST_SEGMENT_S
         for the first .m4s segment to appear.
      4. Return a GENERATED m3u8 with the segment URLs rewritten
         to include the auth token.

    AVPlayer is a system component — it can't add Authorization
    headers to its requests. The standard pattern for HLS with
    auth is to put the token in the query string of every URL
    (the m3u8 + each segment). Apple Music, Spotify, YouTube Music
    all do this. The token has a long lifetime (days), so it
    doesn't expire mid-playback.
    """
    from urllib.parse import unquote
    auth_header = request.headers.get('Authorization') or ''
    if not auth_header:
        query_token = request.query_params.get('token')
        if query_token:
            auth_header = f'Bearer {unquote(query_token)}'
    user = current_user_from_request(auth_header)
    if not user:
        raise HTTPException(status_code=401, detail="unauthorized")

    # Cache hit: redirect to /audio. The token from this request
    # becomes the token in the redirect URL — same pattern.
    cache_path = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache') / f"{video_id}.m4a"
    if cache_path.exists() and cache_path.stat().st_size > 1000:
        token_param = unquote(request.query_params.get('token', ''))
        if token_param:
            redirect_url = f"/audio/{video_id}.m4a?token={token_param}"
        else:
            # No token in query — check Authorization header was
            # already validated above. The /audio endpoint will
            # look at the same header (it accepts both).
            redirect_url = f"/audio/{video_id}.m4a"
        return RedirectResponse(url=redirect_url, status_code=302)

    # Cache miss: HLS path. Check if a transcode is already
    # running for this videoId; if so, share its segments.
    existing = _hls_status(video_id)
    if existing is None:
        # Start a new HLS transcode. Get the YouTube stream URL
        # first (might be slow on first call, but cached after).
        yt_url = await _get_or_fetch_stream_url(video_id)
        if not yt_url:
            raise HTTPException(status_code=404, detail="No audio stream found")

        # Acquire the per-videoId lock to serialize concurrent
        # requests for the same track. If another caller is
        # already transcoding this track, we'll re-check inside
        # the lock and use their segments instead of starting
        # a duplicate transcode.
        lock = _create_videoId_lock(video_id)
        async with lock:
            # Re-check after acquiring the lock — another caller
            # may have just started a transcode.
            recheck = _hls_status(video_id)
            if recheck is not None:
                existing = recheck
            else:
                done_event = asyncio.Event()
                _hls_register_job(video_id, done_event, _hls_dir_for(video_id))
                # Spawn the worker. NOTE: the worker holds the
                # per-videoId lock for its full duration (via
                # the endpoint's `async with lock`). The worker
                # itself doesn't re-acquire it.
                # We release the lock when this endpoint returns;
                # the worker continues independently. This is
                # fine because the worker is the ONLY writer to
                # data/hls/{videoId}/ at this point.
                asyncio.create_task(_hls_transcode_worker(video_id, yt_url, done_event))
                existing = _hls_status(video_id)

    # S17-H / HLS (2026-08-06): the old code waited up to
    # HLS_MAX_WAIT_FOR_FIRST_SEGMENT_S (30s) for the first
    # segment to appear, then 504'd if yt-dlp + ffmpeg didn't
    # produce one in time. For long tracks like Pink Floyd's
    # Echoes (23 min), cold yt-dlp + ffmpeg first-segment can
    # exceed 30s — the user saw "Couldn't play this track"
    # before the HLS pipeline ever had a chance to stream.
    #
    # New behavior: serve the m3u8 immediately. If ffmpeg has
    # already written one, serve that. If not, return the
    # synthesized placeholder right away.
    #
    # Earlier this endpoint had a 1.5s "poll for ffmpeg to
    # start" that cost up to 1.5s on every cold play. The
    # iOS app's AVPlayer polls the m3u8 every ~1s as part of
    # the HLS live pattern anyway, so the poll just added
    # latency without buying anything. Removed 2026-08-06 after
    # cold-play profiling showed the 1.5s was 30% of the time
    # to first audio.
    #
    # The placeholder MUST include a seg_000 reference. Without
    # it, AVPlayer parses the EVENT playlist, sees zero
    # segments, polls a few times, and bails with
    # AVErrorContentNotUpdated (-11866) + CoreMediaErrorDomain
    # -12888 ("no response for media file in N s"). The 503 +
    # Retry-After on the segment endpoint is what keeps AVPlayer
    # retrying until the real segment lands.
    m3u8_path = _hls_playlist_path(video_id)
    if not m3u8_path.exists():
        return _serve_placeholder_hls_playlist(video_id, request)

    # S17-H / HLS-LATENCY (2026-08-06): defensive check for
    # dead HLS state. If the m3u8 has been written but the
    # first segment is missing on disk, the m3u8 is stale
    # (e.g. the HLS worker died mid-run, or the segments were
    # removed by a cleanup race). Returning the stale m3u8
    # would put AVPlayer into an infinite 503 retry loop on
    # the missing segments (observed 21:29 AEST for
    # 2sHZ4ny_SxU — user stuck >10s on the same playlist).
    #
    # If the first segment is missing, return 503 so AVPlayer
    # backs off (Retry-After: 1 → it will retry every 1s).
    # The next /play/playlist.m3u8 will either see ffmpeg
    # writing a fresh m3u8 (because we just cleaned up the
    # partial dir in the worker's finally clause) or — if
    # no worker is running — re-enter the placeholder path
    # and start a fresh transcode.
    if not _hls_first_segment_path(video_id).exists():
        return Response(
            status_code=503,
            headers={
                "Retry-After": "1",
                "Access-Control-Allow-Origin": "*",
                "Content-Type": "application/x-mpegurl",
            },
            content=b"",
        )

    # Read the m3u8 from disk and rewrite segment URLs to
    # include the auth token. The m3u8 is being written
    # continuously (new segments are appended). We read the
    # current state and serve it.
    return _serve_hls_playlist_with_token(video_id, request)


def _create_videoId_lock(video_id: str):
    """
    Helper: create a per-videoId lock if it doesn't exist yet.
    Returns the lock so callers can `async with` it.
    """
    if video_id not in _videoId_locks:
        _videoId_locks[video_id] = asyncio.Lock()
    return _videoId_locks[video_id]


def _serve_hls_playlist_with_token(video_id: str, request: Request):
    """
    Read the current m3u8 from disk, rewrite segment URLs to
    include the auth token, and return a Response.

    Why generated (not just FileResponse): the m3u8 references
    segments as relative paths like `seg_000.m4s`. AVPlayer would
    then request `/play/{videoId}/seg_000.m4s` — without the
    token. So we rewrite each URL to include the token.
    """
    from urllib.parse import unquote, quote
    raw_token = request.query_params.get('token', '')
    if not raw_token:
        # Should never happen — endpoint requires auth. But if
        # the token is missing, return the raw m3u8 anyway; the
        # segment requests will 401.
        m3u8_path = _hls_playlist_path(video_id)
        return FileResponse(m3u8_path, media_type="application/x-mpegurl")

    token = quote(raw_token, safe='')
    m3u8_path = _hls_playlist_path(video_id)
    try:
        with open(m3u8_path, 'r') as f:
            m3u8_text = f.read()
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="m3u8 not found")

    # Rewrite segment URLs: lines that look like
    #   seg_000.m4s
    # become
    #   seg_000.m4s?token=eyJhbGci...
    # Lines that are not segment references (e.g., start with #)
    # are left as-is, EXCEPT for #EXT-X-MAP which references
    # init.mp4 — that ALSO needs the token. (Bug found 2026-07-30:
    # without rewriting URI="init.mp4", AVPlayer would GET init.mp4
    # without a token and get 401. The audio would still play
    # for a couple of seconds, then fail with a cryptic
    # "operation could not be completed" because init.mp4 is
    # needed to decode the segments.)
    out_lines = []
    for line in m3u8_text.splitlines():
        stripped = line.strip()
        if not stripped:
            out_lines.append(line)
            continue
        if stripped.startswith('#EXT-X-MAP:'):
            # Rewrite URI="init.mp4" → URI="init.mp4?token=..."
            # Preserves the rest of the line (e.g. #EXT-X-MAP:URI="init.mp4",BYTERANGE="...")
            import re
            new_line = re.sub(
                r'URI="([^"]+)"',
                lambda m: f'URI="{m.group(1)}?token={token}"' if '?' not in m.group(1)
                else f'URI="{m.group(1)}&token={token}"',
                line,
            )
            out_lines.append(new_line)
            continue
        if stripped.startswith('#'):
            out_lines.append(line)
            continue
        # Segment URL line: append ?token=...
        # If the line already has a query string, append with &.
        sep = '&' if '?' in stripped else '?'
        out_lines.append(f"{stripped}{sep}token={token}")

    body = '\n'.join(out_lines) + '\n'
    return Response(
        content=body,
        media_type="application/x-mpegurl",
        headers={
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Access-Control-Allow-Origin": "*",
        },
    )


def _serve_placeholder_hls_playlist(video_id: str, request: Request):
    """
    S17-H / HLS (2026-08-06): synthesize a minimal HLS event-style
    playlist when ffmpeg hasn't written the real m3u8 yet. AVPlayer
    can start polling immediately; the real playlist (with growing
    segments) takes over once ffmpeg writes its first m3u8. Standard
    HLS live pattern.

    CRITICAL: this placeholder MUST include a seg_000.m4s reference.
    Without it, AVPlayer parses the EVENT playlist, sees zero
    segments, polls a few times, and bails with
    AVErrorContentNotUpdated (-11866) + CoreMediaErrorDomain
    -12888 ("no response for media file in N s"). The 503 +
    Retry-After: 1 on /play/.../seg_000.m4s is what keeps AVPlayer
    retrying until the real segment lands.

    HLS_SEGMENT_TIME (server.py:2726) is 2s, so we set
    EXT-X-TARGETDURATION:2 and the segment EXTINF:2.0 to match.
    EVENT playlist type means the playlist only grows — no
    segments can be removed from the beginning. VERSION 6 supports
    fMP4 segments.
    """
    from urllib.parse import quote
    raw_token = request.query_params.get('token', '')
    token = quote(raw_token, safe='') if raw_token else ''

    init_uri = "init.mp4"
    if token:
        init_uri += f"?token={token}"

    seg_uri = "seg_000.m4s"
    if token:
        seg_uri += f"?token={token}"

    body = (
        "#EXTM3U\n"
        "#EXT-X-VERSION:7\n"
        "#EXT-X-TARGETDURATION:2\n"
        "#EXT-X-MEDIA-SEQUENCE:0\n"
        "#EXT-X-PLAYLIST-TYPE:EVENT\n"
        f'#EXT-X-MAP:URI="{init_uri}"\n'
        "#EXTINF:2.000000,\n"
        f"{seg_uri}\n"
    )

    return Response(
        content=body,
        media_type="application/x-mpegurl",
        headers={
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Access-Control-Allow-Origin": "*",
        },
    )


@app.api_route("/play/{video_id}/seg_{n}.m4s", methods=["GET", "HEAD"])
@limiter.limit("120/minute")  # higher limit: AVPlayer may poll aggressively
async def play_hls_segment(video_id: str, n: int, request: Request):
    """
    S17-H / S17-PLAY: serve a single HLS .m4s segment.

    The token is in the query string (injected by the m3u8
    endpoint). Auth check: the token must be valid. If the
    segment doesn't exist yet (transcode still in progress),
    return 503 Service Unavailable — AVPlayer will retry
    after a short delay (the HLS spec recommends a small
    back-off for this case).
    """
    from urllib.parse import unquote
    auth_header = request.headers.get('Authorization') or ''
    if not auth_header:
        query_token = request.query_params.get('token')
        if query_token:
            auth_header = f'Bearer {unquote(query_token)}'
    user = current_user_from_request(auth_header)
    if not user:
        raise HTTPException(status_code=401, detail="unauthorized")

    seg_path = HLS_DIR / video_id / f"seg_{n:03d}.m4s"
    if not seg_path.exists():
        # 503 with Retry-After. AVPlayer treats this as "segment
        # not ready yet, retry shortly" — standard for live HLS.
        return Response(
            status_code=503,
            headers={"Retry-After": "1", "Access-Control-Allow-Origin": "*"},
        )

    return FileResponse(
        seg_path,
        media_type="video/iso.segment",  # standard MIME for fMP4 HLS segments
        headers={
            "Cache-Control": "public, max-age=3600",  # segments don't change once written
            "Access-Control-Allow-Origin": "*",
        },
    )


@app.api_route("/play/{video_id}/init.mp4", methods=["GET", "HEAD"])
@limiter.limit("60/minute")
async def play_hls_init(video_id: str, request: Request):
    """
    S17-H / S17-PLAY: serve the fMP4 init segment for HLS.

    fMP4 HLS uses an init.mp4 file at the start of every
    playlist (referenced by the m3u8's #EXT-X-MAP). It contains
    the codec config, timescale, and other track-level metadata
    that each subsequent .m4s segment depends on. Without
    init.mp4, the segments are not decodable on their own.
    """
    from urllib.parse import unquote
    auth_header = request.headers.get('Authorization') or ''
    if not auth_header:
        query_token = request.query_params.get('token')
        if query_token:
            auth_header = f'Bearer {unquote(query_token)}'
    user = current_user_from_request(auth_header)
    if not user:
        raise HTTPException(status_code=401, detail="unauthorized")

    init_path = HLS_DIR / video_id / "init.mp4"
    if not init_path.exists():
        # S17-H / HLS (2026-08-06): the previous behavior was 404,
        # which AVPlayer may treat as fatal. ffmpeg writes init.mp4
        # as part of the HLS output but it lags the m3u8 placeholder
        # by a few hundred ms (the m3u8 header is written first).
        # 503 + Retry-After tells AVPlayer "not ready yet, retry
        # shortly" — same pattern as the segment endpoint at
        # line 3151. Standard HLS live behavior.
        return Response(
            status_code=503,
            headers={"Retry-After": "1", "Access-Control-Allow-Origin": "*"},
        )

    return FileResponse(
        init_path,
        media_type="video/iso.segment",
        headers={
            "Cache-Control": "public, max-age=3600",
            "Access-Control-Allow-Origin": "*",
        },
    )


# S17-H / S17-PLAY (Fix 4 Phase 3, 2026-07-30): on successful
# HLS transcode, also concatenate the segments into a cached
# .m4a so future warm plays use the fast path. This is done in
# the _hls_transcode_worker's success path — but to keep the
# worker focused on its single responsibility (writing HLS),
# the concat is handled by a follow-up task that we schedule
# after the worker completes.
async def _hls_concat_to_m4a(video_id: str):
    """
    After HLS transcode completes, concatenate the segments
    into a single .m4a file and save to the audio cache. The
    future /audio requests for this videoId will then be a
    cache hit (instant).

    Uses ffmpeg's concat demuxer with the m3u8 as input —
    ffmpeg can read HLS directly. The output uses the same
    fMP4 flags as Fix 4 Phase 1 (moov at start, fragments).
    """
    hls_dir = _hls_dir_for(video_id)
    m3u8_path = hls_dir / "playlist.m3u8"
    audio_cache_path = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache') / f"{video_id}.m4a"

    if audio_cache_path.exists() and audio_cache_path.stat().st_size > 1000:
        return  # already cached

    if not m3u8_path.exists():
        return

    # Final m3u8 might not have #EXT-X-ENDLIST yet (the worker
    # wrote it but ffmpeg may have exited before that). Force
    # the endlist for the concat input.
    try:
        with open(m3u8_path, 'r') as f:
            m3u8_text = f.read()
        if '#EXT-X-ENDLIST' not in m3u8_text:
            with open(m3u8_path, 'a') as f:
                if not m3u8_text.endswith('\n'):
                    f.write('\n')
                f.write('#EXT-X-ENDLIST\n')
    except OSError as e:
        logger.warning(f"[hls] couldn't add ENDLIST to {m3u8_path}: {e}")

    try:
        proc = await asyncio.create_subprocess_exec(
            FFMPEG_BIN, '-y', '-loglevel', 'error',
            # -allowed_extensions ALL is required because ffmpeg
            # writes init.mp4 (not init.m4s) for fMP4 HLS — but
            # ffmpeg's HLS demuxer refuses to read it by default
            # (security restriction). ALL is safe here because
            # the m3u8 + segments are coming from our own disk.
            '-allowed_extensions', 'ALL',
            '-i', str(m3u8_path),
            '-c', 'copy',
            '-movflags', '+frag_keyframe+empty_moov+default_base_moof',
            str(audio_cache_path),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode == 0 and audio_cache_path.exists():
            size = audio_cache_path.stat().st_size
            logger.info(f"[hls] Concat to cache: {video_id} → {size} bytes")
        else:
            logger.warning(
                f"[hls] Concat to cache failed for {video_id} (rc={proc.returncode}): "
                f"{stderr.decode(errors='replace')[:200]}"
            )
    except Exception as e:
        logger.error(f"[hls] Concat to cache failed for {video_id}: {e}", exc_info=True)
    finally:
        # Remove the synthetic ENDLIST we added.
        try:
            with open(m3u8_path, 'r') as f:
                content = f.read()
            if content.rstrip().endswith('#EXT-X-ENDLIST') and '#EXT-X-ENDLIST' in content[:-50]:
                with open(m3u8_path, 'w') as f:
                    f.write(content.rstrip().rstrip('#EXT-X-ENDLIST').rstrip() + '\n')
        except OSError:
            pass


# S17-H / HLS (Fix 4 Phase 4): HLS cleanup configuration.
HLS_CLEANUP_ENABLED = os.environ.get("HLS_CLEANUP_ENABLED", "true").lower() in ("1", "true", "yes")
HLS_CLEANUP_INTERVAL_S = int(os.environ.get("HLS_CLEANUP_INTERVAL_S", "3600"))  # 1 hour
HLS_CLEANUP_AGE_S = int(os.environ.get("HLS_CLEANUP_AGE_S", "86400"))  # 24 hours
HLS_CLEANUP_BATCH_SIZE = int(os.environ.get("HLS_CLEANUP_BATCH_SIZE", "10"))


def _hls_cleanup_thread_main():
    """
    S17-H / HLS (Fix 4 Phase 4): entry point for the HLS
    cleanup daemon thread. Sets up a private event loop and
    runs the async loop on it.
    """
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(_hls_cleanup_loop())
    finally:
        loop.close()


async def _hls_cleanup_loop():
    """
    S17-H / HLS (Fix 4 Phase 4): periodic cleanup of HLS
    directories. Runs every HLS_CLEANUP_INTERVAL_S seconds.
    For each HLS dir under data/hls/, check if the
    corresponding audio cache m4a exists (i.e., the transcode
    completed and the m4a was created). If so, and the HLS
    dir is older than HLS_CLEANUP_AGE_S, remove it.

    We don't remove HLS dirs that DON'T have a corresponding
    m4a — those are still useful for the current playback
    session (the user might still be streaming from them).
    """
    while True:
        try:
            await _hls_cleanup_cycle()
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.error(f"HLS cleanup cycle failed: {e}", exc_info=True)
        await asyncio.sleep(HLS_CLEANUP_INTERVAL_S)


async def _hls_cleanup_cycle():
    """
    One HLS cleanup cycle. Removes HLS directories that are
    safe to delete (have a corresponding cached m4a and are
    older than the age threshold).
    """
    if not HLS_DIR.exists():
        return

    audio_cache_dir = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache')
    now = time.time()
    removed = 0
    failed = 0

    for hls_dir in HLS_DIR.iterdir():
        if not hls_dir.is_dir():
            continue
        video_id = hls_dir.name
        # Only remove if the corresponding m4a exists (so
        # future /audio requests are still served from the
        # cache) AND the dir is old enough.
        m4a_path = audio_cache_dir / f"{video_id}.m4a"
        if not (m4a_path.exists() and m4a_path.stat().st_size > 1000):
            continue
        # Check the dir's age (mtime of any file in it)
        try:
            mtime = max(f.stat().st_mtime for f in hls_dir.iterdir() if f.is_file())
        except (OSError, ValueError):
            mtime = hls_dir.stat().st_mtime
        age = now - mtime
        if age < HLS_CLEANUP_AGE_S:
            continue

        # Safe to remove.
        try:
            for f in hls_dir.iterdir():
                f.unlink()
            hls_dir.rmdir()
            removed += 1
            logger.info(
                f"[hls-cleanup] removed {video_id} (age={int(age)}s, "
                f"m4a={m4a_path.stat().st_size} bytes)"
            )
        except OSError as e:
            failed += 1
            logger.warning(f"[hls-cleanup] failed to remove {video_id}: {e}")
        if removed + failed >= HLS_CLEANUP_BATCH_SIZE:
            break  # throttle: don't clean too many at once

    if removed or failed:
        logger.info(
            f"[hls-cleanup] cycle done: removed={removed}, failed={failed}"
        )


async def _hls_concat_and_cleanup(video_id: str) -> None:
    """
    After HLS transcode completes: concat segments to cached
    .m4a, then unregister the job. The concat task also writes
    a small grace period to allow late segment requests from
    AVPlayer to resolve before the job is removed from the
    active jobs dict.
    """
    try:
        await _hls_concat_to_m4a(video_id)
    finally:
        # Small grace period so any in-flight segment requests
        # from AVPlayer resolve. The segments don't disappear
        # from disk — they're just no longer tracked in memory.
        await asyncio.sleep(30)
        _hls_unregister_job(video_id)


async def _prewarm_loop():
    """
    S17-H / S17-PLAY (Fix 5): pre-warm background task. Runs
    every PREWARM_INTERVAL seconds. For each user seen in the
    last PREWARM_USER_LOOKBACK_DAYS days, reads the user's
    recently-played list from the iOS sync blob and calls
    /prefetch for the top N entries that aren't already cached.

    Stage 1 (this implementation): just the last 10 recently
    played videoIds per user. No play-count analysis needed —
    the sync blob already has the data. Stage 2 (deferred):
    smarter selection by play count over 30 days, requires
    adding play_count tracking.

    Pre-warming the cache is opt-in by default (PREWARM_ENABLED).
    On a single-Mac dev box, 10 tracks per user * hourly cycle
    is fine (10 transcodes/hour is well within the global
    semaphore cap of 2). For a busier deployment, lower the
    interval or the top_n.
    """
    # Wait a bit on first start so the server has time to bind
    # the port and the iOS app (if it was the trigger) has
    # time to make its first request. Otherwise we'd race with
    # the just-completed startup and pre-warm the same track
    # the user just opened.
    await asyncio.sleep(60)
    while True:
        try:
            await _prewarm_cycle()
        except asyncio.CancelledError:
            raise
        except Exception as e:
            # Never let an exception kill the pre-warm loop.
            # Just log and try again next interval.
            logger.error(f"Pre-warm cycle failed: {e}", exc_info=True)
        await asyncio.sleep(PREWARM_INTERVAL)


async def _prewarm_cycle():
    """
    S17-H / S17-PLAY (Fix 5): one pre-warm cycle. Lists active
    users, reads each user's recently-played list, calls
    /prefetch for the top N that aren't already cached.

    Concurrency: respects _transcode_semaphore (cap=2) by
    delegating to _prefetch_worker (which awaits the helper,
    which awaits the semaphore). So 10 pre-warm calls
    serialize through the same 2-concurrent cap as a real
    user request — the burst is not amplified by pre-warm.

    Privacy: this runs on the user's own server. The data is
    not exposed externally. No leak.
    """
    t0 = time.monotonic()
    user_dir = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/users')
    if not user_dir.exists():
        logger.info("Pre-warm: no users yet, skipping cycle")
        return

    user_files = list(user_dir.glob('*.json'))
    if not user_files:
        logger.info("Pre-warm: no users found, skipping cycle")
        return

    cache = get_cache()
    audio_cache_dir = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/audio_cache')

    # Collect (videoId, user_id) pairs to pre-warm. Dedup by
    # videoId — if two users have the same track, only
    # pre-warm it once.
    to_warm: dict[str, str] = {}  # videoId -> first user_id (for logging)
    skipped_cached = 0
    skipped_old = 0

    for user_file in user_files:
        user_id = user_file.stem
        try:
            user_blob = json.loads(user_file.read_text())
        except (json.JSONDecodeError, OSError) as e:
            logger.warning(f"Pre-warm: couldn't read {user_file.name}: {e}")
            continue

        # Skip users not seen in the last N days. The user file
        # stores the unix timestamp as `last_seen_at` (older
        # versions used ISO-format `last_seen`).
        last_seen_ts = user_blob.get("last_seen_at") or user_blob.get("last_seen")
        if last_seen_ts is not None:
            try:
                # If it's a float, treat as unix timestamp; if string,
                # try ISO parse.
                if isinstance(last_seen_ts, (int, float)):
                    age_days = (datetime.datetime.utcnow() - datetime.datetime.utcfromtimestamp(float(last_seen_ts))).days
                else:
                    last_seen_dt = datetime.datetime.fromisoformat(str(last_seen_ts))
                    age_days = (datetime.datetime.utcnow() - last_seen_dt).days
                if age_days > PREWARM_USER_LOOKBACK_DAYS:
                    continue
            except (ValueError, TypeError):
                pass  # bad/missing date — try the user anyway

        # Get the recently-played list. The sync blob (separate
        # file) has a "history" array of {videoId, playedAt, progress}
        # entries sorted ascending by playedAt — so the most-recent
        # is at the END. Take the last PREWARM_TOP_N.
        sync_file = Path('/Users/coderbat/iYMusic/YTAudioSystem/backend/data/sync') / f"{user_id}.json"
        if not sync_file.exists():
            continue
        try:
            sync_blob = json.loads(sync_file.read_text())
        except (json.JSONDecodeError, OSError) as e:
            logger.warning(f"Pre-warm: couldn't read sync blob for {user_id}: {e}")
            continue
        history = sync_blob.get("history") or []
        if not isinstance(history, list):
            continue
        # Sort by playedAt descending, take top N
        sorted_history = sorted(
            [e for e in history if isinstance(e, dict) and e.get("videoId")],
            key=lambda e: e.get("playedAt") or 0,
            reverse=True,
        )
        recent = sorted_history[:PREWARM_TOP_N]

        for entry in recent:
            video_id = entry.get("videoId") or entry.get("video_id")
            if not video_id:
                continue
            # Already queued (dedup across users)?
            if video_id in to_warm:
                continue
            # Already cached?
            cache_path = audio_cache_dir / f"{video_id}.m4a"
            if cache_path.exists() and cache_path.stat().st_size > 1000:
                skipped_cached += 1
                continue
            to_warm[video_id] = user_id

    if not to_warm:
        logger.info(
            f"Pre-warm cycle: nothing to warm "
            f"({skipped_cached} already cached, {skipped_old} skipped). "
            f"{time.monotonic() - t0:.1f}s"
        )
        return

    logger.info(
        f"Pre-warm cycle: warming {len(to_warm)} tracks "
        f"({skipped_cached} already cached)"
    )

    # Fire-and-forget the workers. _prefetch_worker respects
    # _transcode_semaphore, so even with 10 concurrent calls
    # the actual transcode work is capped at 2.
    for video_id, user_id in to_warm.items():
        try:
            # Reuse the existing worker. The user_id is for
            # logging only — the transcode doesn't need auth.
            asyncio.create_task(_prefetch_worker(video_id, user_id))
        except Exception as e:
            logger.warning(f"Pre-warm: failed to enqueue {video_id}: {e}")

    logger.info(
        f"Pre-warm cycle: enqueued {len(to_warm)} tracks "
        f"in {time.monotonic() - t0:.1f}s (transcodes will run "
        f"serially via the cap=2 semaphore)"
    )


@app.on_event("shutdown")
async def shutdown_event():
    """Graceful shutdown: clean up resources"""
    logger.info("Shutting down application...")
    global _http_session
    if _http_session:
        _http_session.close()
        _http_session = None
        logger.info("HTTP session closed")
    logger.info("Shutdown complete")


# Run server
if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", 8181))
    host = os.environ.get("HOST", "0.0.0.0")

    print(f"Starting YT Audio Backend on {host}:{port}")
    print(f"Library directory: {get_extractor().output_dir}")

    client = get_client()
    if client.authenticated:
        print("✓ Authenticated mode - full features enabled")
    else:
        print("i️  Guest mode - run 'make auth' for library access")

    uvicorn.run(app, host=host, port=port, log_level="info")
