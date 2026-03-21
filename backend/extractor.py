"""
Audio Extraction Pipeline
Handles downloading and converting YouTube audio streams.
"""

import yt_dlp
import ffmpeg
import os
import tempfile
import shutil
from pathlib import Path
from typing import Optional, Dict, List
import logging
import requests

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class AudioExtractor:
    """
    Extracts audio from YouTube/YouTube Music URLs.
    Converts to iOS-compatible M4A format with metadata.
    """
    
    # Format preference order (best quality first)
    PREFERRED_FORMATS = ['251', '140', '250', '249']
    # 251: Opus 160kbps (best)
    # 140: AAC 128kbps (iOS native)
    # 250: Opus 70kbps
    # 249: Opus 50kbps
    
    def __init__(self, output_dir: str = "~/Music/YTAudio"):
        """
        Initialize extractor with output directory.
        
        Args:
            output_dir: Directory to save converted files
        """
        self.output_dir = Path(output_dir).expanduser()
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        # yt-dlp base options
        self.ydl_opts = {
            'format': 'bestaudio/best',
            'quiet': True,
            'no_warnings': True,
            'extract_audio': False,
            'skip_download': True,
        }
    
    def get_audio_info(self, video_id: str) -> Optional[Dict]:
        """
        Get audio stream information without downloading.
        
        Args:
            video_id: YouTube video ID
            
        Returns:
            Dictionary with stream URL and metadata
        """
        url = f"https://music.youtube.com/watch?v={video_id}"
        
        try:
            with yt_dlp.YoutubeDL(self.ydl_opts) as ydl:
                info = ydl.extract_info(url, download=False)
                
                if not info:
                    return None
                
                # Find audio-only formats
                audio_formats = [
                    f for f in info.get('formats', [])
                    if f.get('acodec') != 'none' and f.get('vcodec') == 'none'
                ]
                
                if not audio_formats:
                    logger.warning(f"No audio-only formats for {video_id}")
                    return None
                
                # Sort by our preference order, then by bitrate
                def sort_key(fmt):
                    itag = str(fmt.get('format_id', ''))
                    if itag in self.PREFERRED_FORMATS:
                        return (self.PREFERRED_FORMATS.index(itag), 0)
                    return (999, -fmt.get('abr', 0))
                
                audio_formats.sort(key=sort_key)
                best = audio_formats[0]
                
                return {
                    'url': best.get('url'),
                    'ext': best.get('ext'),
                    'abr': best.get('abr', 0),
                    'codec': best.get('acodec'),
                    'filesize': best.get('filesize') or best.get('filesize_approx', 0),
                    'format_id': best.get('format_id'),
                    'duration': info.get('duration', 0)
                }
                
        except Exception as e:
            logger.error(f"Audio info extraction failed: {e}")
            return None
    
    def download_and_convert(
        self, 
        video_id: str, 
        metadata: Dict[str, str],
        quality: str = "128k"
    ) -> Optional[Path]:
        """
        Download audio and convert to M4A format.
        
        Args:
            video_id: YouTube video ID
            metadata: Dictionary with 'title', 'artists', 'album'
            quality: AAC bitrate (default 128k)
            
        Returns:
            Path to converted file, or None if failed
        """
        # Get stream info
        stream_info = self.get_audio_info(video_id)
        if not stream_info:
            logger.error(f"Could not get stream info for {video_id}")
            return None
        
        # Create safe filename
        title = metadata.get('title', 'Unknown')
        artists = metadata.get('artists', ['Unknown'])
        
        safe_title = "".join(c for c in title if c.isalnum() or c in (' ', '-', '_')).strip()
        safe_artist = "".join(c for c in artists[0] if c.isalnum() or c in (' ', '-', '_')).strip()
        
        filename = f"{safe_title} - {safe_artist}.m4a"
        output_path = self.output_dir / filename
        
        # Check if already exists
        if output_path.exists():
            logger.info(f"File already exists: {output_path}")
            return output_path
        
        # Download to temp file
        temp_path = self.output_dir / f".temp_{video_id}.{stream_info['ext']}"
        
        try:
            logger.info(f"Downloading {video_id}...")
            self._download_stream(stream_info['url'], temp_path)
            
            logger.info(f"Converting to M4A...")
            self._convert_to_m4a(
                temp_path, 
                output_path, 
                metadata,
                quality
            )
            
            logger.info(f"Saved to {output_path}")
            return output_path
            
        except Exception as e:
            logger.error(f"Download/convert failed: {e}")
            # Cleanup
            if temp_path.exists():
                temp_path.unlink()
            if output_path.exists():
                output_path.unlink()
            return None
    
    def _download_stream(self, url: str, output_path: Path) -> None:
        """
        Download stream from URL to file.
        
        Args:
            url: Direct stream URL
            output_path: Where to save
        """
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        }
        
        with requests.get(url, headers=headers, stream=True, timeout=30) as r:
            r.raise_for_status()
            with open(output_path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
    
    def _convert_to_m4a(
        self,
        input_path: Path,
        output_path: Path,
        metadata: Dict[str, str],
        quality: str
    ) -> None:
        """
        Convert downloaded file to M4A with metadata and artwork.

        Args:
            input_path: Source file (webm, m4a, etc)
            output_path: Destination M4A file
            metadata: Track metadata (may include 'thumbnail' URL)
            quality: AAC bitrate
        """
        import subprocess
        import tempfile

        # Prepare metadata strings
        title = metadata.get('title', 'Unknown Title')
        artist = ', '.join(metadata.get('artists', ['Unknown Artist']))
        album = metadata.get('album', 'Unknown Album')
        thumbnail_url = metadata.get('thumbnail')

        # Download artwork if available
        artwork_path = None
        if thumbnail_url:
            try:
                headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
                response = requests.get(thumbnail_url, headers=headers, timeout=10)
                if response.status_code == 200:
                    with tempfile.NamedTemporaryFile(suffix='.jpg', delete=False) as f:
                        f.write(response.content)
                        artwork_path = f.name
                        logger.info(f"Downloaded artwork: {artwork_path}")
            except Exception as e:
                logger.warning(f"Could not download artwork: {e}")

        # Build ffmpeg command
        if artwork_path and Path(artwork_path).exists():
            # Two-pass approach for artwork embedding in M4A
            # First, convert audio to temporary M4A
            temp_audio = output_path.with_suffix('.tmp.m4a')
            cmd_audio = [
                'ffmpeg',
                '-y',
                '-i', str(input_path),
                '-vn',
                '-c:a', 'aac',
                '-b:a', quality,
                '-ar', '44100',
                '-metadata', f'title={title}',
                '-metadata', f'artist={artist}',
                '-metadata', f'album={album}',
                '-metadata', 'comment=Extracted from YouTube Music',
                '-f', 'ipod',
                str(temp_audio)
            ]

            # Second, embed artwork
            cmd_embed = [
                'ffmpeg',
                '-y',
                '-i', str(temp_audio),
                '-i', artwork_path,
                '-map', '0:a',
                '-map', '1:v',
                '-c:a', 'copy',
                '-c:v', 'mjpeg',
                '-disposition:v', 'attached_pic',
                str(output_path)
            ]
        else:
            # No artwork, single pass
            cmd_audio = [
                'ffmpeg',
                '-y',
                '-i', str(input_path),
                '-vn',
                '-c:a', 'aac',
                '-b:a', quality,
                '-ar', '44100',
                '-metadata', f'title={title}',
                '-metadata', f'artist={artist}',
                '-metadata', f'album={album}',
                '-metadata', 'comment=Extracted from YouTube Music',
                '-f', 'ipod',
                str(output_path)
            ]
            cmd_embed = None

        try:
            # Run audio conversion
            result = subprocess.run(
                cmd_audio,
                capture_output=True,
                text=True,
                check=True
            )

            # Embed artwork if available
            if cmd_embed:
                result = subprocess.run(
                    cmd_embed,
                    capture_output=True,
                    text=True,
                    check=True
                )
                logger.info(f"Embedded artwork in: {output_path}")

            # Cleanup temp files
            if artwork_path:
                Path(artwork_path).unlink(missing_ok=True)
            if 'temp_audio' in locals():
                temp_audio.unlink(missing_ok=True)

            logger.info(f"FFmpeg conversion successful: {output_path}")
        except subprocess.CalledProcessError as e:
            logger.error(f"FFmpeg error: {e.stderr}")
            raise RuntimeError(f"FFmpeg conversion failed: {e.stderr}")
        finally:
            # Cleanup temp file
            if input_path.exists():
                input_path.unlink()
    
    def list_library(self) -> List[Dict]:
        """
        List all downloaded tracks in library.
        
        Returns:
            List of track info dictionaries
        """
        tracks = []
        
        for f in self.output_dir.glob("*.m4a"):
            if f.name.startswith('.'):
                continue
                
            stat = f.stat()
            tracks.append({
                'filename': f.name,
                'path': str(f),
                'size': stat.st_size,
                'size_human': self._human_readable_size(stat.st_size),
                'modified': stat.st_mtime
            })
        
        # Sort by modification time (newest first)
        tracks.sort(key=lambda x: x['modified'], reverse=True)
        return tracks
    
    def delete_file(self, filename: str) -> bool:
        """
        Delete a file from the library.
        
        Args:
            filename: Name of the file to delete
            
        Returns:
            True if deleted, False if not found
        """
        file_path = self.output_dir / filename
        
        # Security: ensure file is within output_dir
        try:
            file_path.resolve().relative_to(self.output_dir.resolve())
        except ValueError:
            logger.warning(f"Attempted to delete file outside output directory: {filename}")
            return False
        
        if file_path.exists():
            try:
                file_path.unlink()
                logger.info(f"Deleted file: {filename}")
                return True
            except Exception as e:
                logger.error(f"Failed to delete file {filename}: {e}")
                return False
        
        return False
    
    def _human_readable_size(self, size_bytes: int) -> str:
        """Convert bytes to human readable string."""
        for unit in ['B', 'KB', 'MB', 'GB']:
            if size_bytes < 1024.0:
                return f"{size_bytes:.1f} {unit}"
            size_bytes /= 1024.0
        return f"{size_bytes:.1f} TB"


# Singleton instance
_extractor = None

def get_extractor() -> AudioExtractor:
    """Get or create singleton extractor instance."""
    global _extractor
    if _extractor is None:
        _extractor = AudioExtractor()
    return _extractor
