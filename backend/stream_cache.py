"""
Stream URL Cache
Caches YouTube stream URLs to avoid repeated yt-dlp extractions.
URLs expire after 3.5 hours (YouTube URLs typically last 4-6 hours).
"""

import time
import threading
from typing import Optional, Dict
import logging

logger = logging.getLogger(__name__)


class StreamCache:
    """
    Thread-safe cache for YouTube stream URLs.
    """
    
    # URLs expire after 3.5 hours (YouTube URLs typically last 4-6 hours)
    DEFAULT_TTL = 3.5 * 60 * 60  # 3.5 hours in seconds
    
    def __init__(self, ttl: float = DEFAULT_TTL):
        self.ttl = ttl
        self._cache: Dict[str, dict] = {}
        self._lock = threading.RLock()
        
        # Start cleanup thread
        self._cleanup_interval = 300  # 5 minutes
        self._stop_cleanup = threading.Event()
        self._cleanup_thread = threading.Thread(target=self._cleanup_loop, daemon=True)
        self._cleanup_thread.start()
    
    def get(self, video_id: str) -> Optional[dict]:
        """
        Get cached stream data for a video ID.
        
        Args:
            video_id: YouTube video ID
            
        Returns:
            Cached stream data or None if not found/expired
        """
        with self._lock:
            entry = self._cache.get(video_id)
            if not entry:
                return None
            
            # Check if expired
            if time.time() > entry['expires_at']:
                logger.info(f"Cache entry expired for {video_id}")
                del self._cache[video_id]
                return None
            
            logger.info(f"Cache HIT for {video_id}")
            return entry['data']
    
    def set(self, video_id: str, data: dict) -> None:
        """
        Cache stream data for a video ID.
        
        Args:
            video_id: YouTube video ID
            data: Stream data to cache
        """
        with self._lock:
            self._cache[video_id] = {
                'data': data,
                'expires_at': time.time() + self.ttl,
                'created_at': time.time()
            }
            logger.info(f"Cache SET for {video_id}")
    
    def invalidate(self, video_id: str) -> None:
        """Remove a specific video ID from cache."""
        with self._lock:
            if video_id in self._cache:
                del self._cache[video_id]
                logger.info(f"Cache INVALIDATE for {video_id}")
    
    def clear(self) -> None:
        """Clear all cached entries."""
        with self._lock:
            self._cache.clear()
            logger.info("Cache CLEARED")
    
    def get_stats(self) -> dict:
        """Get cache statistics."""
        with self._lock:
            total = len(self._cache)
            expired = sum(1 for entry in self._cache.values() 
                         if time.time() > entry['expires_at'])
            return {
                'total_entries': total,
                'expired_entries': expired,
                'valid_entries': total - expired
            }
    
    def _cleanup_loop(self) -> None:
        """Background thread to clean up expired entries."""
        while not self._stop_cleanup.wait(self._cleanup_interval):
            self._cleanup_expired()
    
    def _cleanup_expired(self) -> None:
        """Remove expired entries from cache."""
        now = time.time()
        with self._lock:
            expired_ids = [
                video_id for video_id, entry in self._cache.items()
                if now > entry['expires_at']
            ]
            for video_id in expired_ids:
                del self._cache[video_id]
            
            if expired_ids:
                logger.info(f"Cache cleanup: removed {len(expired_ids)} expired entries")
    
    def stop(self) -> None:
        """Stop the cleanup thread."""
        self._stop_cleanup.set()
        self._cleanup_thread.join(timeout=1.0)


# Singleton instance
_cache_instance: Optional[StreamCache] = None


def get_cache() -> StreamCache:
    """Get or create the singleton cache instance."""
    global _cache_instance
    if _cache_instance is None:
        _cache_instance = StreamCache()
    return _cache_instance


def reset_cache() -> None:
    """Reset the singleton cache instance."""
    global _cache_instance
    if _cache_instance:
        _cache_instance.stop()
    _cache_instance = None
