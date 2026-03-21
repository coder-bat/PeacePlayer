"""
FastAPI Server
HTTP interface for iOS client to access extraction capabilities.
Works with or without authentication.
"""

from fastapi import FastAPI, HTTPException, BackgroundTasks, Request, Response
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, ConfigDict
from pydantic.alias_generators import to_camel
from typing import List, Optional
import os
import asyncio
import logging
from pathlib import Path

from ytm_client import YTMusicClient, get_client, reset_client
from extractor import AudioExtractor, get_extractor
from stream_cache import get_cache

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

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
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Pydantic models for request/response validation
class SearchQuery(BaseModel):
    query: str = Field(..., description="Search string")
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


# Health check
@app.get("/")
async def root():
    client = get_client()
    return {
        "status": "running",
        "service": "YT Audio Backend",
        "authenticated": client.authenticated,
        "mode": "authenticated" if client.authenticated else "guest"
    }


@app.get("/auth-status", response_model=AuthStatusResponse)
async def auth_status():
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
async def refresh_auth():
    """Reload authentication (call after running setup_oauth.py)."""
    reset_client()
    client = get_client()
    return {
        "authenticated": client.authenticated,
        "message": "Authentication reloaded"
    }


@app.get("/cache/stats")
async def cache_stats():
    """Get stream URL cache statistics."""
    cache = get_cache()
    return cache.get_stats()


@app.post("/cache/clear")
async def cache_clear():
    """Clear the stream URL cache."""
    cache = get_cache()
    cache.clear()
    return {"message": "Cache cleared"}


# Search endpoint
@app.post("/search", response_model=List[TrackResponse])
async def search(query: SearchQuery):
    """
    Search YouTube Music for tracks.
    Works in both authenticated and guest mode.
    """
    try:
        client = get_client()
        results = client.search_tracks(query.query, query.limit)
        
        if not results:
            return []
        
        return [TrackResponse(**track).model_dump() for track in results]
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")


# Playlist search endpoint
@app.post("/search/playlists", response_model=List[PlaylistResponse])
async def search_playlists(query: SearchQuery):
    """
    Search YouTube Music for playlists.
    Works in both authenticated and guest mode.
    """
    try:
        client = get_client()
        results = client.search_playlists(query.query, query.limit)
        return results
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Playlist search failed: {str(e)}")


# Get playlist details endpoint
@app.get("/playlist/{playlist_id}", response_model=PlaylistDetailsResponse)
async def get_playlist(playlist_id: str, limit: int = 100):
    """
    Get full playlist details including tracks.
    """
    try:
        client = get_client()
        playlist = client.get_playlist(playlist_id, limit=limit)
        
        if not playlist:
            raise HTTPException(status_code=404, detail="Playlist not found")
        
        return playlist
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get playlist: {str(e)}")


# Stream endpoint
@app.get("/stream/{video_id}", response_model=StreamResponse)
async def stream_audio(video_id: str):
    """
    Get streaming URL for a video.
    Works in both authenticated and guest mode.
    Uses caching for faster responses.
    """
    try:
        # Check cache first
        cache = get_cache()
        stream_data = cache.get(video_id)
        
        if not stream_data:
            logger.info(f"Cache miss for {video_id}, fetching from YouTube...")
            client = get_client()
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
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Stream extraction failed: {str(e)}")


# Proxy stream endpoint - streams through backend to avoid IP issues
@app.api_route("/proxy-stream/{video_id:path}", methods=["GET", "HEAD"])
async def proxy_stream_audio(video_id: str, request: Request, quality: str = "high"):
    """
    Proxy stream audio through backend.
    This avoids IP-mismatch issues between backend and iOS client.
    Uses caching to avoid repeated yt-dlp extractions.

    Query params:
        quality: "low" for fast start (70kbps), "high" for best quality (160kbps)
    """
    import requests

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
        if request.method == "HEAD":
            logger.info("Handling HEAD request")
            yt_headers = {
                'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
                'Referer': 'https://music.youtube.com/',
                'Accept': '*/*',
                'Accept-Encoding': 'identity'
            }
            
            # Do a HEAD request to YouTube to get headers
            r = requests.head(stream_url, headers=yt_headers, timeout=30)
            
            response_headers = {
                'Content-Type': mime_type,
                'Accept-Ranges': 'bytes',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Range'
            }
            
            if 'Content-Length' in r.headers:
                response_headers['Content-Length'] = r.headers['Content-Length']
            
            logger.info(f"HEAD response headers: {response_headers}")
            return Response(headers=response_headers, status_code=r.status_code)
        
        # Handle GET request
        # Headers for YouTube request
        yt_headers = {
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
            'Referer': 'https://music.youtube.com/',
            'Accept': '*/*',
            'Accept-Encoding': 'identity',
            'Connection': 'keep-alive'
        }
        
        # Forward range header from client if present (for seeking)
        if 'range' in request.headers:
            yt_headers['Range'] = request.headers['range']
            logger.info(f"Forwarding Range: {request.headers['range']}")
        
        # Make request to YouTube
        r = requests.get(stream_url, headers=yt_headers, stream=True, timeout=60)
        r.raise_for_status()
        
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
        
        return StreamingResponse(
            r.iter_content(chunk_size=65536),
            status_code=r.status_code,
            headers=response_headers
        )
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Proxy stream failed: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Stream failed: {str(e)}")


# Download endpoint
@app.post("/download", response_model=DownloadResponse)
async def download_track(request: DownloadRequest):
    """
    Download and convert track to local M4A file.
    Works in both authenticated and guest mode.
    """
    try:
        extractor = get_extractor()
        
        metadata = {
            'title': request.title,
            'artists': request.artists,
            'album': request.album,
            'thumbnail': request.thumbnail
        }
        
        loop = asyncio.get_event_loop()
        result_path = await loop.run_in_executor(
            None, 
            extractor.download_and_convert,
            request.video_id,
            metadata
        )
        
        if not result_path:
            raise HTTPException(status_code=500, detail="Download or conversion failed")
        
        return DownloadResponse(
            status="completed",
            filePath=str(result_path)
        )
        
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Download failed: {str(e)}")


# Library listing
@app.get("/library")
async def list_library():
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
        raise HTTPException(status_code=500, detail=f"Library listing failed: {str(e)}")


# Library delete endpoint
@app.delete("/library/{filename}")
async def delete_library_file(filename: str):
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
        raise HTTPException(status_code=500, detail=f"Delete failed: {str(e)}")


# Local file streaming
@app.get("/local-play/{filename}")
async def play_local_file(filename: str):
    """
    Stream a local M4A file.
    Supports HTTP range requests for seeking.
    """
    try:
        extractor = get_extractor()
        file_path = extractor.output_dir / filename
        
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
        raise HTTPException(status_code=500, detail=f"File serving failed: {str(e)}")


# Thumbnail proxy
@app.get("/thumbnail")
async def proxy_thumbnail(url: str):
    """
    Proxy thumbnail image to avoid CORS issues on iOS.
    """
    import requests
    
    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        
        return StreamingResponse(
            content=iter([response.content]),
            media_type=response.headers.get('content-type', 'image/jpeg')
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Thumbnail fetch failed: {str(e)}")


# Lyrics endpoint
@app.get("/lyrics/{video_id}")
async def get_lyrics(video_id: str):
    """
    Get lyrics for a track if available.
    """
    try:
        client = get_client()
        lyrics = client.get_lyrics(video_id)
        
        if not lyrics:
            raise HTTPException(status_code=404, detail="Lyrics not available")
        
        return {"lyrics": lyrics}
        
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Lyrics fetch failed: {str(e)}")


# Radio/Autoplay
@app.get("/radio/{video_id}")
async def get_radio(video_id: str):
    """
    Get radio playlist based on track.
    Works in both authenticated and guest mode.
    """
    try:
        client = get_client()
        tracks = client.get_watch_playlist(video_id)
        return [TrackResponse(**track).model_dump() for track in tracks]
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Radio generation failed: {str(e)}")


# Authenticated-only endpoints
@app.get("/liked-songs")
async def get_liked_songs():
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
        tracks = client.get_liked_songs()
        return {"tracks": tracks}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get liked songs: {str(e)}")


@app.get("/playlists")
async def get_playlists():
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
        playlists = client.get_library_playlists()
        return {"playlists": playlists}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get playlists: {str(e)}")


# Charts / Trending
@app.get("/charts")
async def get_charts():
    """
    Get trending charts from YouTube Music.
    Returns trending songs by category (all genres).
    Works in both authenticated and guest mode.
    Falls back to search-based results if API returns empty.
    """
    try:
        client = get_client()
        tracks = []

        # Try to get charts from YTMusic API (may fail in guest mode)
        try:
            charts = client.yt.get_charts(country='US')  # Default to US charts

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
            tracks = client.search_tracks(query, limit=20)

        return {"tracks": [TrackResponse(**track).model_dump() for track in tracks[:20]]}
    except Exception as e:
        logger.error(f"Charts fetch failed: {e}")
        # Return empty list on error rather than failing
        return {"tracks": []}


@app.get("/new-releases")
async def get_new_releases():
    """
    Get new releases from YouTube Music.
    Returns latest album/song releases.
    Works in both authenticated and guest mode.
    Falls back to search-based results if API returns empty.
    """
    try:
        client = get_client()
        tracks = []

        # Try to get new releases from YTMusic API
        try:
            releases = client.yt.get_new_releases(country='US')

            if releases:
                # Parse new releases - they're albums, extract tracks
                for album in releases[:15]:  # Limit to first 15 albums
                    try:
                        album_id = album.get('browseId')
                        if album_id:
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
            tracks = client.search_tracks(query, limit=20)

        return {"tracks": [TrackResponse(**track).model_dump() for track in tracks[:20]]}
    except Exception as e:
        logger.error(f"New releases fetch failed: {e}")
        return {"tracks": []}


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
