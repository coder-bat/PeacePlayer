"""
FastAPI Server
HTTP interface for iOS client to access extraction capabilities.
Works with or without authentication.
"""

from fastapi import FastAPI, HTTPException, BackgroundTasks, Request, Response, Query
from fastapi.responses import FileResponse, StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from pydantic import BaseModel, Field, ConfigDict
from pydantic.alias_generators import to_camel
from typing import List, Optional
import os
import asyncio
import logging
import json
import time
import uuid
import glob as _glob
import datetime
import requests as _requests
from pathlib import Path

from ytm_client import YTMusicClient, get_client, reset_client
from extractor import AudioExtractor, get_extractor
from stream_cache import get_cache

# --- Configuration from environment ---
STREAM_CONNECT_TIMEOUT = float(os.environ.get("STREAM_CONNECT_TIMEOUT", "5"))
STREAM_READ_TIMEOUT = float(os.environ.get("STREAM_READ_TIMEOUT", "30"))
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
limiter = Limiter(key_func=get_remote_address)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)


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


@app.get("/cache/stats")
@limiter.limit("15/minute")
async def cache_stats(request: Request):
    """Get stream URL cache statistics."""
    cache = get_cache()
    return cache.get_stats()


@app.post("/cache/clear")
@limiter.limit("15/minute")
async def cache_clear(request: Request):
    """Clear the stream URL cache."""
    cache = get_cache()
    cache.clear()
    return {"message": "Cache cleared"}


# Search endpoint
@app.post("/search", response_model=List[TrackResponse])
@limiter.limit("10/minute")
async def search(query: SearchQuery, request: Request):
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
async def search_playlists(query: SearchQuery, request: Request):
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
async def get_playlist(playlist_id: str, request: Request, limit: int = Query(default=100, ge=1, le=200)):
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
async def stream_audio(video_id: str, request: Request):
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
    """

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
        yt_headers = {
            'Referer': 'https://music.youtube.com/',
            'Accept': '*/*',
            'Accept-Encoding': 'identity',
            'Connection': 'keep-alive'
        }
        
        # Forward range header from client if present (for seeking)
        if 'range' in request.headers:
            yt_headers['Range'] = request.headers['range']
            logger.info(f"Forwarding Range: {request.headers['range']}")
        
        # Make request to YouTube using connection pool
        session = get_http_session()
        r = session.get(stream_url, headers=yt_headers, stream=True, timeout=(STREAM_CONNECT_TIMEOUT, STREAM_READ_TIMEOUT))
        try:
            r.raise_for_status()
        except Exception:
            r.close()
            raise
        
        logger.info(f"YouTube response: status={r.status_code}, content-type={r.headers.get('Content-Type')}, length={r.headers.get('Content-Length', 'unknown')}")
        
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
        
        def stream_with_close():
            try:
                for chunk in r.iter_content(chunk_size=65536):
                    if chunk:
                        yield chunk
            finally:
                r.close()
        
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


# Download endpoint
@app.post("/download", response_model=DownloadResponse)
@limiter.limit("15/minute")
async def download_track(download_req: DownloadRequest, request: Request):
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
async def list_library(request: Request):
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
async def delete_library_file(filename: str, request: Request):
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
async def get_waveform(video_id: str, request: Request):
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
async def local_play(filename: str, request: Request):
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
async def proxy_thumbnail(url: str, request: Request):
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
async def get_lyrics(video_id: str, request: Request):
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
async def get_radio(video_id: str, request: Request):
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
async def get_liked_songs(request: Request):
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
async def get_playlists(request: Request):
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
async def get_charts(request: Request):
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
async def get_new_releases(request: Request):
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
        print("ℹ️  Guest mode - run 'make auth' for library access")
    
    uvicorn.run(app, host=host, port=port, log_level="info")
