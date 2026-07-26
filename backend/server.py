"""
FastAPI Server
HTTP interface for iOS client to access extraction capabilities.
Works with or without authentication.
"""

from fastapi import FastAPI, HTTPException, BackgroundTasks, Request, Response, Query, Path as APIPath, Depends
from fastapi.responses import FileResponse, StreamingResponse, JSONResponse
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
#   /proxy-stream                 : 20/min — each request is one
#                                  song; a user skipping a few
#                                  times lands at 5-10/min.
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
@app.get("/stream/{video_id}", response_model=StreamResponse)
@limiter.limit("20/minute")
async def stream_audio(video_id: str, request: Request, user: dict = Depends(require_session_user),):
    """Get streaming URL for a video. Uses caching."""
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

            # Cache the stream data
            cache.set(video_id, stream_data)

        best = stream_data['audio_formats'][0]

        logger.info(f"Returning stream URL: {best['url'][:50]}...")

        return StreamResponse(
            streamUrl=best['url'],
            mimeType=best['mime_type'],
            bitrate=best['bitrate']
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Stream extraction failed")
        raise HTTPException(status_code=500, detail=f"Stream extraction failed: {str(e)}")


# Proxy stream endpoint - streams through backend to avoid IP issues
@app.api_route("/proxy-stream/{video_id:path}", methods=["GET", "HEAD"])
@limiter.limit("20/minute")
async def proxy_stream_audio(video_id: str, request: Request, quality: str = "high"):
    """
    Proxy stream audio through backend.
    This avoids IP-mismatch issues between backend and iOS client.
    Uses caching to avoid repeated yt-dlp extractions.

    Query params:
        quality: "low" for fast start (70kbps), "high" for best quality (160kbps)
        token:   session JWT — only used as a fallback when the
                 Authorization header is missing. AVPlayer (a
                 system component, not URLSession) opens the stream
                 URL directly and cannot add the iOS app's auth
                 header, so the iOS code passes the token via
                 ?token=... instead. See
                 ios/Sources/APIService.swift#getStreamUrl for the
                 counterpart.
    """
    # S17-H follow-up: AVPlayer can't add the iOS app's Bearer
    # token to its GET request, so every play was 401-ing and
    # bubbling up as "Couldn't play this track after multiple
    # attempts. Skipping to the next one." — the audio never
    # started. Accept the token from the Authorization header
    # first (the secure path), and fall back to the ?token=
    # query param for AVPlayer-initiated requests. The query
    # path is intentionally scoped to this endpoint so the
    # token doesn't leak into /search / /library / etc. URLs.
    auth_header = request.headers.get("Authorization")
    if not auth_header:
        query_token = request.query_params.get("token")
        if query_token:
            auth_header = f"Bearer {query_token}"
    user = current_user_from_request(auth_header)
    if not user:
        raise HTTPException(status_code=401, detail="unauthorized")

    # Determine preferred format from extension
    prefer_m4a = video_id.endswith('.m4a')
    prefer_webm = video_id.endswith('.webm')

    # Strip extension if present
    if prefer_m4a:
        video_id = video_id[:-4]
    elif prefer_webm:
        video_id = video_id[:-5]

    try:
        # Check cache first
        cache = get_cache()
        stream_data = cache.get(video_id)

        if not stream_data:
            logger.info(f"Cache miss for {video_id}, fetching from YouTube...")
            client = get_client()
            async with ytmusic_lock:
                stream_data = client.get_stream_url(video_id)

            if not stream_data or not stream_data.get('audio_formats'):
                raise HTTPException(status_code=404, detail="No audio stream found")

            # Cache the stream data
            cache.set(video_id, stream_data)
        else:
            logger.info(f"Using cached stream data for {video_id}")

        # Sort formats based on quality preference
        audio_formats = stream_data['audio_formats']

        if quality == "low":
            # For fast start: prefer lower bitrate, smaller filesize
            audio_formats.sort(key=lambda x: (
                x.get('bitrate', 999999),  # Lower bitrate first
                x.get('filesize', 999999999)  # Smaller file first
            ))
            logger.info(f"Using low quality (fast start) for {video_id}")
        else:
            # High quality: prefer requested type, then highest bitrate
            if prefer_m4a:
                audio_formats.sort(key=lambda x: (
                    0 if x.get('mime_type') == 'm4a' else 1,
                    -x.get('bitrate', 0)  # Higher bitrate first
                ))
            elif prefer_webm:
                audio_formats.sort(key=lambda x: (
                    0 if x.get('mime_type') == 'webm' else 1,
                    -x.get('bitrate', 0)
                ))
            else:
                audio_formats.sort(key=lambda x: -x.get('bitrate', 0))
            logger.info(f"Using high quality for {video_id}")

        best = audio_formats[0]
        stream_url = best['url']
        mime_type = best.get('mime_type', 'audio/mp4')

        # Fix MIME type for iOS AVPlayer
        if mime_type in ['m4a', 'audio/m4a', 'audio/x-m4a']:
            mime_type = 'audio/mp4'
        elif mime_type == 'webm':
            mime_type = 'audio/webm'

        logger.info(f"Proxy streaming: {stream_url[:60]}... (mime: {mime_type}, method: {request.method})")

        # Handle HEAD request - AVPlayer probes with HEAD first
        # Use cached data to avoid round-trip to YouTube
        if request.method == "HEAD":
            logger.info("Handling HEAD request (using cached metadata)")
            response_headers = {
                'Content-Type': mime_type,
                'Accept-Ranges': 'bytes',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Range'
            }

            content_length = best.get('content_length')
            if content_length and content_length > 0:
                response_headers['Content-Length'] = str(content_length)

            logger.info(f"HEAD response headers: {response_headers}")
            return Response(headers=response_headers, status_code=200)

        # Handle GET request
        # Headers for YouTube request
        # S17-H (2026-07-26): YouTube was closing the upstream
        # connection after a few seconds of streaming, which surfaced
        # to the iOS app as "Couldn't play this track after multiple
        # attempts. Skipping to the next one." for every track. The
        # proxy was sending httpx's default User-Agent
        # ("python-httpx/0.x.y") which YouTube's bot detection
        # matches and mid-stream-throttles. Use a desktop Chrome UA
        # — same one yt-dlp uses for extraction so the URL's
        # signature is consistent with the headers we send.
        yt_headers = {
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': 'https://music.youtube.com/',
            'Accept': '*/*',
            'Accept-Encoding': 'identity',
            'Connection': 'keep-alive'
        }

        # Forward range header from client if present (for seeking)
        if 'range' in request.headers:
            yt_headers['Range'] = request.headers['range']
            logger.info(f"Forwarding Range: {request.headers['range']}")

        # S15: this used to be a synchronous `requests.get(...,
        # stream=True)` call inside an `async def` route, which
        # blocks the FastAPI event loop for the entire duration
        # of the upstream read. With multiple concurrent
        # /proxy-stream requests, every other request stalls while
        # the slowest upstream read finishes. Switch to
        # `httpx.AsyncClient` + `aiter_bytes` so the event loop
        # stays responsive while the upstream bytes stream in.
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(
                connect=STREAM_CONNECT_TIMEOUT,
                read=STREAM_READ_TIMEOUT,
                write=STREAM_READ_TIMEOUT,
                pool=STREAM_CONNECT_TIMEOUT,
            ),
            follow_redirects=True,
        ) as client:
            upstream_req = client.build_request(
                "GET", stream_url, headers=yt_headers
            )
            r = await client.send(upstream_req, stream=True)
            try:
                r.raise_for_status()
            except Exception:
                await r.aclose()
                raise

            logger.info(
                f"YouTube response: status={r.status_code}, "
                f"content-type={r.headers.get('Content-Type')}, "
                f"length={r.headers.get('Content-Length', 'unknown')}"
            )

            # Build response headers
            response_headers = {
                'Content-Type': mime_type,
                'Accept-Ranges': 'bytes',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Range',
                'Access-Control-Expose-Headers': 'Content-Length, Content-Range'
            }

            # Forward content length if available
            if 'Content-Length' in r.headers:
                response_headers['Content-Length'] = r.headers['Content-Length']

            # Forward content range if available (for partial content)
            if 'Content-Range' in r.headers:
                response_headers['Content-Range'] = r.headers['Content-Range']

            logger.info(f"Proxy response headers: {response_headers}")

            async def stream_with_close():
                try:
                    async for chunk in r.aiter_bytes(chunk_size=65536):
                        if chunk:
                            yield chunk
                finally:
                    await r.aclose()

            return StreamingResponse(
                stream_with_close(),
                status_code=r.status_code,
                headers=response_headers
            )

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Proxy stream failed")
        raise HTTPException(status_code=500, detail=f"Stream failed: {str(e)}")


# Prefetch endpoint - fire-and-forget cache warming
@app.post("/prefetch/{video_id}")
@limiter.limit("60/minute")
async def prefetch_stream(video_id: str, background_tasks: BackgroundTasks, request: Request, user: dict = Depends(require_session_user),):
    """
    Fire-and-forget endpoint to warm the stream URL cache.
    Returns 202 Accepted immediately; extraction runs in background.
    """
    cache = get_cache()
    if cache.get(video_id):
        return {"status": "already_cached"}

    background_tasks.add_task(_prefetch_worker, video_id)
    return {"status": "accepted"}


async def _prefetch_worker(video_id: str):
    """
    Background worker: run yt-dlp extraction with proper locking.
    """
    try:
        client = get_client()
        async with ytmusic_lock:
            stream_data = client.get_stream_url(video_id)

        if stream_data and stream_data.get("audio_formats"):
            get_cache().set(video_id, stream_data)
            logger.info(f"Prefetch cached: {video_id}")
        else:
            logger.warning(f"Prefetch found no audio formats: {video_id}")
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
