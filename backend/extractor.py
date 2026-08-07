"""
Audio Extraction Pipeline
Handles downloading and converting YouTube audio streams.
"""

import yt_dlp
import ffmpeg
import os
import subprocess
import tempfile
import shutil
import time
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

        # S15: use a Unicode-aware sanitizer. The previous
        # `c.isalnum()` check strips all CJK characters (and any
        # other non-ASCII letter/digit), so a Mandarin / Japanese
        # / Korean title becomes an empty string and the
        # download fails the moment the file system rejects an
        # empty filename. We allow Unicode letters, marks, and
        # numbers, plus space/hyphen/underscore/parentheses for
        # common music-title characters. Anything else (control
        # chars, slashes, colons) is replaced with a hyphen.
        import re
        _keep_pattern = re.compile(
            r"[^\w\s\-\u2014\u2013()\u3000\u3001\u3002\u2026]",
            re.UNICODE,
        )
        safe_title = _keep_pattern.sub('-', title).strip()
        if not safe_title:
            safe_title = f"track-{video_id}"
        safe_artist = _keep_pattern.sub('-', artists[0]).strip() if artists else "Unknown Artist"
        if not safe_artist:
            safe_artist = f"artist-{video_id}"

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

        S17-H / DOWNLOAD-CDN-FIX (2026-08-07): YouTube's CDN throttles
        long-lived HTTP/1.1 connections — a full unresumed download
        stalls mid-stream at ~1.8-2.5MB even though the server returns
        Content-Length: 3.4MB. The truncated file gets passed to
        ffmpeg, which produces a partial .m4a; iOS plays the first
        few seconds then stops. Symptom in the iOS app: "downloaded
        in KBs" + "only first segment played".

        YouTube also rate-limits yt-dlp's native downloader to
        ~31KB/s on this network (3.4MB takes 100s+). The Range-
        chunked download we use here downloads 1MB per request in
        ~90ms each, completing the full file in <500ms — about
        200× faster than yt-dlp's default downloader.

        Args:
            url: Direct stream URL
            output_path: Where to save
        """
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        }

        # Primary path: Range-based chunked download. We do an initial
        # `Range: bytes=0-0` request to get Content-Range (which
        # includes the total file size), then loop over 1MB ranges.
        # YouTube's CDN rejects HEAD requests with 403, so we have
        # to use a 1-byte Range request as our size probe. Each chunk
        # is short-lived (~90ms for 1MB) so YouTube's connection
        # throttle doesn't kick in.
        with requests.get(
            url,
            headers={**headers, 'Range': 'bytes=0-0'},
            timeout=10,
        ) as probe:
            probe.raise_for_status()
            cr = probe.headers.get('Content-Range', '')
            # Content-Range: bytes 0-0/3433755
            if '/' not in cr:
                raise RuntimeError(
                    f"Could not determine Content-Length for {url[:80]} "
                    f"(no Content-Range in response)"
                )
            total = int(cr.split('/')[-1])
            if total == 0:
                raise RuntimeError(
                    f"Could not determine Content-Length for {url[:80]}"
                )

        logger.info(
            f"Downloading {total} bytes via Range chunks"
        )
        chunk_size = 1 * 1024 * 1024  # 1MB
        downloaded = 0
        start = time.monotonic()
        with open(output_path, 'wb') as f:
            while downloaded < total:
                end = min(downloaded + chunk_size - 1, total - 1)
                with requests.get(
                    url,
                    headers={**headers, 'Range': f'bytes={downloaded}-{end}'},
                    timeout=10,
                ) as r:
                    r.raise_for_status()
                    for chunk in r.iter_content(chunk_size=8192):
                        if chunk:
                            f.write(chunk)
                            downloaded += len(chunk)
        elapsed = time.monotonic() - start
        rate = total / elapsed / 1024 if elapsed > 0 else 0
        logger.info(
            f"Downloaded {total} bytes in {elapsed:.2f}s ({rate:.0f} KB/s)"
        )
    
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
    
    def generate_waveform(self, audio_path: Path, peaks: int = 200) -> List[float]:
        """
        Generate normalized waveform peak data from a local audio file using ffmpeg.

        Decodes audio to raw 32-bit float PCM at 8000 Hz mono, splits into `peaks`
        equal-length segments, computes RMS amplitude per segment, and normalizes to 0.0–1.0.

        Args:
            audio_path: Path to the local M4A/audio file.
            peaks: Number of amplitude values to return (default 200).

        Returns:
            List of `peaks` floats in range [0.0, 1.0], or empty list on failure.
        """
        import struct
        import math

        try:
            cmd = [
                'ffmpeg', '-i', str(audio_path),
                '-af', 'aresample=8000',
                '-ac', '1',
                '-f', 'f32le',
                '-acodec', 'pcm_f32le',
                'pipe:1',
                '-loglevel', 'error'
            ]
            result = subprocess.run(cmd, capture_output=True, timeout=30)
            if result.returncode != 0 or not result.stdout:
                logger.warning(f"ffmpeg waveform extraction failed for {audio_path.name}")
                return []

            raw = result.stdout
            sample_count = len(raw) // 4  # 4 bytes per float32
            if sample_count < peaks:
                logger.warning(f"Not enough samples for waveform: {sample_count}")
                return []

            samples = struct.unpack(f'{sample_count}f', raw)
            chunk_size = sample_count // peaks
            rms_values = []

            for i in range(peaks):
                start = i * chunk_size
                chunk = samples[start:start + chunk_size]
                rms = math.sqrt(sum(s * s for s in chunk) / len(chunk))
                rms_values.append(rms)

            # Normalize to 0.0–1.0
            max_val = max(rms_values) if rms_values else 1.0
            if max_val < 1e-8:
                return [0.0] * peaks

            normalized = [min(1.0, v / max_val) for v in rms_values]

            # Light smoothing pass (3-sample moving average)
            smoothed = normalized[:]
            for i in range(1, len(normalized) - 1):
                smoothed[i] = (normalized[i - 1] + normalized[i] + normalized[i + 1]) / 3.0

            return smoothed

        except subprocess.TimeoutExpired:
            logger.error(f"Waveform generation timed out for {audio_path.name}")
            return []
        except Exception as e:
            logger.error(f"Waveform generation error: {e}")
            return []

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
