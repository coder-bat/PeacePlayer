"""
Radio Mix Cache
Caches YouTube "Up Next" radio playlists to avoid repeated yt-dlp
RD-list extractions.

Pattern mirrors stream_cache.py but with a longer TTL (UpNext is
"what's related to this song today" — changes slowly) and a hard
size cap with LRU eviction (single user can play many distinct seeds;
we don't want the dict to grow without bound).
"""

import time
import threading
from collections import OrderedDict
from typing import Optional, Dict, List
import logging

logger = logging.getLogger(__name__)


class RadioCache:
    """
    Thread-safe LRU cache for radio mix (UpNext) playlists.

    Each entry is the JSON-serialisable list of TrackResponse dicts
    returned by the /radio/{video_id} endpoint.
    """

    # 24 hours: UpNext is "what's related to this song today". A
    # user's listening history changes slowly; refresh once a day is
    # plenty. LRU evicts under load even before TTL.
    DEFAULT_TTL = 24 * 60 * 60

    # 500 entries: a single user playing 500 distinct songs in 24h
    # is generous (the heavy listener case). LRU evicts the oldest
    # when we exceed this. Each entry is ~3KB, so the cap is ~1.5MB.
    DEFAULT_MAX_ENTRIES = 500

    def __init__(self, ttl: float = DEFAULT_TTL, max_entries: int = DEFAULT_MAX_ENTRIES):
        self.ttl = ttl
        self.max_entries = max_entries
        # OrderedDict so we can do LRU (move_to_end on get, popitem
        # oldest on overflow). Using an OrderedDict instead of a
        # plain dict keeps the implementation simple — no heap, no
        # doubly-linked list, and 500 entries is small enough that
        # the O(n) popitem on overflow is fine.
        self._cache: "OrderedDict[str, dict]" = OrderedDict()
        self._lock = threading.RLock()

        # Background cleanup (mirrors StreamCache).
        self._cleanup_interval = 300  # 5 minutes
        self._stop_cleanup = threading.Event()
        self._cleanup_thread = threading.Thread(target=self._cleanup_loop, daemon=True)
        self._cleanup_thread.start()

    def get(self, video_id: str) -> Optional[List[Dict]]:
        """
        Get cached UpNext list for a video ID.

        Args:
            video_id: YouTube video ID (the seed track)

        Returns:
            Cached list of track dicts, or None if not found / expired
        """
        with self._lock:
            entry = self._cache.get(video_id)
            if not entry:
                return None

            if time.time() > entry['expires_at']:
                logger.info(f"[radio_cache] EXPIRED for {video_id}")
                del self._cache[video_id]
                return None

            # LRU: move to end so this is the most-recently-used entry.
            # The next eviction will drop the LEAST-recently-used
            # (front of the OrderedDict).
            self._cache.move_to_end(video_id)

            logger.info(f"[radio_cache] HIT for {video_id} ({len(entry['data'])} tracks)")
            return entry['data']

    def set(self, video_id: str, data: List[Dict]) -> None:
        """
        Cache UpNext list for a video ID.

        Args:
            video_id: YouTube video ID (the seed track)
            data: List of track dicts (the UpNext response body)
        """
        with self._lock:
            # Empty list means /radio failed. Don't cache failure —
            # the next call should retry the network request.
            if not data:
                return

            self._cache[video_id] = {
                'data': data,
                'expires_at': time.time() + self.ttl,
                'created_at': time.time(),
            }
            # Move to end (most-recently-used).
            self._cache.move_to_end(video_id)

            # LRU eviction: if we're over the cap, drop the oldest
            # entries until we're under. We only evict in set() —
            # get() doesn't insert so it can't overflow.
            while len(self._cache) > self.max_entries:
                evicted_id, _ = self._cache.popitem(last=False)
                logger.info(f"[radio_cache] LRU evicted {evicted_id}")

            logger.info(f"[radio_cache] SET for {video_id} ({len(data)} tracks, total={len(self._cache)})")

    def invalidate(self, video_id: str) -> None:
        """Remove a specific video ID from cache."""
        with self._lock:
            if video_id in self._cache:
                del self._cache[video_id]
                logger.info(f"[radio_cache] INVALIDATE for {video_id}")

    def clear(self) -> None:
        """Clear all cached entries."""
        with self._lock:
            self._cache.clear()
            logger.info("[radio_cache] CLEARED")

    def get_stats(self) -> dict:
        """Get cache statistics. Useful for /cache/stats endpoint."""
        with self._lock:
            now = time.time()
            total = len(self._cache)
            expired = sum(1 for entry in self._cache.values() if now > entry['expires_at'])
            return {
                'total_entries': total,
                'expired_entries': expired,
                'valid_entries': total - expired,
                'max_entries': self.max_entries,
                'ttl_seconds': self.ttl,
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
                logger.info(f"[radio_cache] cleanup: removed {len(expired_ids)} expired entries")

    def stop(self) -> None:
        """Stop the cleanup thread. Call on backend shutdown."""
        self._stop_cleanup.set()
        self._cleanup_thread.join(timeout=1.0)


# Singleton instance
_cache_instance: Optional[RadioCache] = None


def get_radio_cache() -> RadioCache:
    """Get or create the singleton radio cache instance."""
    global _cache_instance
    if _cache_instance is None:
        _cache_instance = RadioCache()
    return _cache_instance


def reset_radio_cache() -> None:
    """Reset the singleton radio cache instance (test helper)."""
    global _cache_instance
    if _cache_instance:
        _cache_instance.stop()
    _cache_instance = None
