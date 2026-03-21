"""
YouTube Music API Client
Handles search, metadata retrieval, and stream URL extraction.
Supports both authenticated and guest (unauthenticated) modes.
"""

from ytmusicapi import YTMusic, setup
from typing import List, Dict, Optional
import os
import logging
import yt_dlp

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class YTMusicClient:
    """
    Wrapper around ytmusicapi for structured data access.
    Works with or without authentication.
    """
    
    def __init__(self, auth_file: str = "oauth.json"):
        """
        Initialize client with optional authentication.
        
        Args:
            auth_file: Path to auth credentials file. If not found, uses guest mode.
        """
        self.auth_file = auth_file
        self.authenticated = False
        self.yt = None
        
        # Try authenticated mode first
        if os.path.exists(auth_file):
            try:
                logger.info(f"Loading authenticated session from {auth_file}")
                self.yt = YTMusic(auth_file)
                self.authenticated = True
                logger.info("✓ Authenticated mode enabled")
            except Exception as e:
                logger.warning(f"Failed to load auth file: {e}")
                logger.info("Falling back to guest mode...")
        
        # Fall back to guest mode if auth fails or doesn't exist
        if self.yt is None:
            try:
                logger.info("Initializing in guest mode (no authentication)")
                self.yt = YTMusic()  # Guest mode - no auth needed
                logger.info("✓ Guest mode enabled - search and streaming work")
                logger.info("  (For personal library access, run: make auth)")
            except Exception as e:
                logger.error(f"Failed to initialize YTMusic: {e}")
                raise
    
    def search_tracks(self, query: str, limit: int = 20) -> List[Dict]:
        """
        Search for songs on YouTube Music.
        Works in both authenticated and guest mode.
        
        Args:
            query: Search string
            limit: Maximum results to return
            
        Returns:
            List of track dictionaries with metadata
        """
        try:
            results = self.yt.search(query, filter="songs", limit=limit)
            
            tracks = []
            for item in results:
                if item.get('resultType') != 'song':
                    continue
                
                track = {
                    'videoId': item.get('videoId'),
                    'title': item.get('title', 'Unknown Title'),
                    'artists': [a.get('name', 'Unknown') for a in item.get('artists', [])],
                    'album': item.get('album', {}).get('name', 'Unknown Album'),
                    'durationSeconds': item.get('duration_seconds', 0),
                    'thumbnails': item.get('thumbnails', []),
                    'isExplicit': item.get('isExplicit', False),
                    'videoType': item.get('videoType', 'UNKNOWN')
                }
                tracks.append(track)
            
            logger.info(f"Search for '{query}' returned {len(tracks)} tracks")
            return tracks
            
        except Exception as e:
            logger.error(f"Search failed: {e}")
            return []
    
    def search_playlists(self, query: str, limit: int = 10) -> List[Dict]:
        """
        Search for playlists on YouTube Music.
        Works in both authenticated and guest mode.
        
        Args:
            query: Search string
            limit: Maximum results to return
            
        Returns:
            List of playlist dictionaries with metadata
        """
        try:
            logger.info(f"Searching playlists for: '{query}'")
            results = self.yt.search(query, filter="playlists", limit=limit)
            logger.info(f"Raw search returned {len(results)} results")
            
            playlists = []
            for item in results:
                result_type = item.get('resultType')
                logger.debug(f"Result type: {result_type}, Title: {item.get('title', 'N/A')}")
                
                if result_type != 'playlist':
                    continue
                
                # Get playlist ID from browseId (format: VLxxxxx or just xxxxx)
                browse_id = item.get('browseId', '')
                # Remove VL prefix if present
                if browse_id and browse_id.startswith('VL'):
                    playlist_id = browse_id[2:]
                else:
                    playlist_id = browse_id
                
                if not playlist_id:
                    logger.debug(f"Skipping playlist without ID: {item.get('title')}")
                    continue
                
                # Extract video count from string like "50 songs" or "50 videos"
                count_str = item.get('itemCount', '0')
                try:
                    video_count = int(''.join(filter(str.isdigit, count_str)))
                except:
                    video_count = 0
                
                # Parse thumbnails into iOS-compatible format
                raw_thumbnails = item.get('thumbnails', [])
                formatted_thumbnails = []
                for thumb in raw_thumbnails:
                    if isinstance(thumb, dict) and 'url' in thumb:
                        formatted_thumbnails.append({
                            'url': thumb['url'],
                            'width': thumb.get('width', 0),
                            'height': thumb.get('height', 0)
                        })
                
                # Handle author - can be string or dict
                author_data = item.get('author', 'Unknown')
                if isinstance(author_data, dict):
                    author_name = author_data.get('name', 'Unknown')
                elif isinstance(author_data, str):
                    author_name = author_data
                else:
                    author_name = 'Unknown'
                
                playlist = {
                    'playlistId': playlist_id,
                    'title': item.get('title', 'Unknown Playlist'),
                    'author': author_name,
                    'videoCount': video_count,
                    'thumbnails': formatted_thumbnails,
                    'description': item.get('description', '')[:100]  # Truncate
                }
                playlists.append(playlist)
                logger.debug(f"Added playlist: {playlist['title']} ({playlist['videoCount']} videos)")
            
            logger.info(f"Playlist search for '{query}' returned {len(playlists)} playlists")
            return playlists
            
        except Exception as e:
            logger.error(f"Playlist search failed: {e}")
            import traceback
            traceback.print_exc()
            return []
    
    def get_playlist(self, playlist_id: str, limit: int = 100) -> Optional[Dict]:
        """
        Get full playlist details including tracks.
        
        Args:
            playlist_id: YouTube playlist ID
            limit: Maximum tracks to fetch
            
        Returns:
            Playlist dictionary with tracks or None
        """
        try:
            playlist_data = self.yt.get_playlist(playlist_id, limit=limit)
            
            if not playlist_data:
                return None
            
            # Helper to format thumbnails
            def format_thumbnails(thumbnails):
                if not thumbnails:
                    return []
                formatted = []
                for thumb in thumbnails:
                    if isinstance(thumb, dict) and 'url' in thumb:
                        formatted.append({
                            'url': thumb['url'],
                            'width': thumb.get('width', 0),
                            'height': thumb.get('height', 0)
                        })
                return formatted
            
            # Parse tracks
            tracks = []
            for track in playlist_data.get('tracks', []):
                # Skip tracks without videoId
                video_id = track.get('videoId')
                if not video_id:
                    continue
                
                # Handle album which can be None
                album_data = track.get('album')
                album_name = 'Unknown Album'
                if album_data and isinstance(album_data, dict):
                    album_name = album_data.get('name', 'Unknown Album')
                
                parsed_track = {
                    'videoId': video_id,
                    'title': track.get('title') or 'Unknown Title',
                    'artists': [a.get('name', 'Unknown') for a in track.get('artists', []) if a and a.get('name')],
                    'album': album_name,
                    'durationSeconds': track.get('duration_seconds') or 0,
                    'thumbnails': format_thumbnails(track.get('thumbnails', [])),
                    'isExplicit': track.get('isExplicit') or False,
                    'videoType': track.get('videoType') or 'MUSIC_VIDEO_TYPE_ATV'
                }
                tracks.append(parsed_track)
            
            # Handle author - playlist data uses 'artists' or we can extract from tracks
            author_name = 'Unknown'
            if playlist_data.get('artists'):
                artist_names = [a.get('name', '') for a in playlist_data['artists'] if a and a.get('name')]
                if artist_names:
                    author_name = ', '.join(artist_names)
            elif tracks:
                # Use first track's artist as fallback
                author_name = tracks[0]['artists'][0] if tracks[0]['artists'] else 'Unknown'
            
            # Get thumbnails from first track if playlist has none
            thumbnails = format_thumbnails(playlist_data.get('thumbnails', []))
            if not thumbnails and tracks:
                thumbnails = tracks[0].get('thumbnails', [])
            
            return {
                'playlistId': playlist_id,
                'title': playlist_data.get('title', 'Unknown Playlist'),
                'author': author_name,
                'videoCount': len(tracks),
                'thumbnails': thumbnails,
                'description': (playlist_data.get('description') or '')[:200],
                'tracks': tracks
            }
            
        except Exception as e:
            logger.error(f"Failed to get playlist {playlist_id}: {e}")
            import traceback
            traceback.print_exc()
            return None
    
    def get_stream_url(self, video_id: str) -> Optional[Dict]:
        """
        Get direct audio stream URLs for a video.
        Uses yt-dlp to get playable URLs (handles signature deciphering).
        Works in both authenticated and guest mode.
        
        Args:
            video_id: YouTube video ID
            
        Returns:
            Dictionary with stream URLs and metadata, or None if failed
        """
        try:
            url = f"https://music.youtube.com/watch?v={video_id}"
            
            ydl_opts = {
                'format': 'bestaudio/best',
                'quiet': True,
                'skip_download': True,
                'extract_flat': False,
            }
            
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=False)
                
                if not info:
                    logger.error(f"No info extracted for {video_id}")
                    return None
                
                # Get all formats and filter for audio-only
                formats = info.get('formats', [])
                audio_formats = []
                
                for fmt in formats:
                    # Audio-only formats have vcodec='none' and acodec!='none'
                    vcodec = fmt.get('vcodec', 'none')
                    acodec = fmt.get('acodec', 'none')
                    
                    if vcodec == 'none' and acodec != 'none':
                        abr = fmt.get('abr') or fmt.get('tbr') or 0
                        audio_formats.append({
                            'itag': fmt.get('format_id'),
                            'url': fmt.get('url'),
                            'mime_type': fmt.get('ext', 'audio/unknown'),
                            'bitrate': int(abr * 1000),
                            'content_length': fmt.get('filesize') or 0,
                            'audio_sample_rate': str(fmt.get('asr', '48000')),
                            'format_note': fmt.get('format_note', ''),
                        })
                
                if not audio_formats:
                    logger.warning(f"No audio-only formats found for {video_id}, trying any audio format")
                    # Fallback: include any format with audio
                    for fmt in formats:
                        acodec = fmt.get('acodec', 'none')
                        if acodec != 'none':
                            abr = fmt.get('abr') or fmt.get('tbr') or 0
                            audio_formats.append({
                                'itag': fmt.get('format_id'),
                                'url': fmt.get('url'),
                                'mime_type': fmt.get('ext', 'audio/unknown'),
                                'bitrate': int(abr * 1000),
                                'content_length': fmt.get('filesize') or 0,
                                'audio_sample_rate': str(fmt.get('asr', '48000')),
                                'format_note': fmt.get('format_note', ''),
                            })
                
                if not audio_formats:
                    logger.error(f"No audio formats found for {video_id}")
                    return None
                
                # Sort by bitrate (highest first)
                audio_formats.sort(key=lambda x: x['bitrate'], reverse=True)
                
                logger.info(f"Found {len(audio_formats)} audio formats for {video_id}")
                
                return {
                    'video_id': video_id,
                    'audio_formats': audio_formats,
                    'expires_in_seconds': 21600,  # 6 hours typical
                    'title': info.get('title', ''),
                    'duration': info.get('duration', 0),
                }
            
        except Exception as e:
            logger.error(f"Stream URL extraction failed for {video_id}: {e}")
            return None
    
    def get_lyrics(self, video_id: str) -> Optional[str]:
        """
        Get lyrics for a song if available.
        
        Args:
            video_id: YouTube video ID
            
        Returns:
            Lyrics text or None
        """
        try:
            # First get watch playlist to find lyrics ID
            watch_playlist = self.yt.get_watch_playlist(video_id)
            
            if not watch_playlist or 'lyrics' not in watch_playlist:
                logger.debug(f"No lyrics ID found for {video_id}")
                return None
            
            lyrics_id = watch_playlist['lyrics']
            logger.debug(f"Found lyrics ID: {lyrics_id} for video: {video_id}")
            
            # Get lyrics using the lyrics ID
            lyrics_data = self.yt.get_lyrics(lyrics_id)
            if lyrics_data and 'lyrics' in lyrics_data:
                return lyrics_data['lyrics']
            
            return None
        except Exception as e:
            logger.error(f"Lyrics fetch failed for {video_id}: {e}")
            return None
    
    def get_watch_playlist(self, video_id: str) -> List[Dict]:
        """
        Get radio/playlist based on a song (autoplay).
        
        Args:
            video_id: Seed video ID
            
        Returns:
            List of related tracks
        """
        try:
            playlist = self.yt.get_watch_playlist(video_id)
            tracks = []
            
            raw_tracks = playlist.get('tracks', [])

            # Get video IDs that need duration fetched
            video_ids = [item.get('videoId') for item in raw_tracks if item.get('videoId')]

            # Batch fetch song details to get durations
            durations = {}
            if video_ids:
                try:
                    # Fetch details for songs that don't have duration in watch playlist
                    for vid in video_ids[:10]:  # Limit to first 10 to avoid rate limiting
                        try:
                            song_detail = self.yt.get_song(vid)
                            if song_detail and 'videoDetails' in song_detail:
                                details = song_detail['videoDetails']
                                # Try multiple fields for duration
                                duration = details.get('lengthSeconds') or details.get('duration_seconds')
                                if duration:
                                    durations[vid] = int(duration)
                        except Exception as e:
                            logger.debug(f"Failed to get song details for {vid}: {e}")
                            continue
                except Exception as e:
                    logger.warning(f"Failed to fetch song durations: {e}")

            for item in raw_tracks:
                # Handle album which can be None
                album_data = item.get('album')
                album_name = 'Unknown Album'
                if album_data and isinstance(album_data, dict):
                    album_name = album_data.get('name', 'Unknown Album')

                # Note: watch playlist returns 'thumbnail' (singular), not 'thumbnails'
                thumbnails = item.get('thumbnail', [])

                # Try to get duration from multiple sources
                vid = item.get('videoId')
                duration = (item.get('lengthSeconds') or
                           item.get('duration_seconds') or
                           durations.get(vid, 0))

                track = {
                    'videoId': vid,
                    'title': item.get('title', 'Unknown Title'),
                    'artists': [a.get('name', 'Unknown') for a in item.get('artists', []) if a],
                    'album': album_name,
                    'durationSeconds': duration,
                    'thumbnails': thumbnails,
                    'isExplicit': item.get('isExplicit', False),
                    'videoType': item.get('videoType', 'MUSIC_VIDEO_TYPE_ATV')
                }
                tracks.append(track)

            logger.info(f"Fetched {len(tracks)} tracks from watch playlist, {sum(1 for t in tracks if t['durationSeconds'] > 0)} have duration")
            return tracks
        except Exception as e:
            logger.error(f"Watch playlist fetch failed: {e}")
            import traceback
            traceback.print_exc()
            return []
    
    def get_library_playlists(self) -> List[Dict]:
        """
        Get user's playlists (authenticated only).
        
        Returns:
            List of playlists or empty list if not authenticated
        """
        if not self.authenticated:
            logger.warning("Library access requires authentication. Run: make auth")
            return []
        
        try:
            playlists = self.yt.get_library_playlists()
            return playlists
        except Exception as e:
            logger.error(f"Failed to get library playlists: {e}")
            return []
    
    def get_liked_songs(self) -> List[Dict]:
        """
        Get user's liked songs (authenticated only).
        
        Returns:
            List of tracks or empty list if not authenticated
        """
        if not self.authenticated:
            logger.warning("Liked songs access requires authentication. Run: make auth")
            return []
        
        try:
            # Get liked songs playlist
            liked = self.yt.get_liked_songs()
            return liked.get('tracks', [])
        except Exception as e:
            logger.error(f"Failed to get liked songs: {e}")
            return []


# Singleton instance
_client = None

def get_client() -> YTMusicClient:
    """Get or create singleton client instance."""
    global _client
    if _client is None:
        _client = YTMusicClient()
    return _client


def reset_client():
    """Reset singleton (useful after auth changes)."""
    global _client
    _client = None
    logger.info("Client reset - will reinitialize on next use")
