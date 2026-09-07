"""Offline cache behavior contracts."""
import unittest

class TestRadioCacheUnit(unittest.TestCase):
    """
    Unit tests for the radio cache itself (no network).
    """

    def setUp(self):
        from radio_cache import RadioCache
        # Use a tiny cache (3 entries) so we can test LRU eviction
        # without making 500 requests.
        self.cache = RadioCache(ttl=60, max_entries=3)

    def test_set_and_get(self):
        self.cache.set("v1", [{"videoId": "a"}, {"videoId": "b"}])
        result = self.cache.get("v1")
        self.assertEqual(result, [{"videoId": "a"}, {"videoId": "b"}])

    def test_empty_set_is_not_cached(self):
        """Failure responses (empty lists) should NOT be cached —
        the next call should retry the network."""
        self.cache.set("v1", [])
        result = self.cache.get("v1")
        self.assertIsNone(result, "Empty list was cached; should be treated as failure")

    def test_lru_eviction(self):
        """When the cache is full, the LEAST-recently-used entry
        should be evicted on the next set()."""
        self.cache.set("v1", [{"videoId": "a"}])
        self.cache.set("v2", [{"videoId": "b"}])
        self.cache.set("v3", [{"videoId": "c"}])
        # v1 is now the LRU
        self.cache.get("v1")  # touch v1 → it's now MRU; v2 is LRU
        # Insert v4 → v2 should be evicted
        self.cache.set("v4", [{"videoId": "d"}])
        self.assertIsNone(self.cache.get("v2"), "LRU entry was not evicted")
        self.assertIsNotNone(self.cache.get("v1"), "MRU entry was wrongly evicted")
        self.assertIsNotNone(self.cache.get("v3"))
        self.assertIsNotNone(self.cache.get("v4"))

    def test_ttl_expiry(self):
        """Expired entries should be returned as None and removed."""
        from radio_cache import RadioCache
        import time as time_module
        cache = RadioCache(ttl=1, max_entries=10)  # 1 second TTL
        cache.set("v1", [{"videoId": "a"}])
        self.assertIsNotNone(cache.get("v1"))
        time_module.sleep(1.1)
        self.assertIsNone(cache.get("v1"), "Expired entry was returned")

    def test_invalidate(self):
        self.cache.set("v1", [{"videoId": "a"}])
        self.cache.invalidate("v1")
        self.assertIsNone(self.cache.get("v1"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
