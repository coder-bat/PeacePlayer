"""Album search + album details mapping contracts (offline, no network)."""
import unittest

from ytm_client import (
    YTMusicClient,
    _album_artist_names,
    _filter_and_sort_albums,
    _map_album_details,
    _map_album_search_item,
    _normalize_artist_name,
)


def _thumb(width: int) -> dict:
    return {
        "url": f"https://yt3.googleusercontent.com/art=w{width}-h{width}-l90-rj",
        "width": width,
        "height": width,
    }


ALBUM_THUMBS = [_thumb(60), _thumb(120), _thumb(226), _thumb(544)]

RADIOHEAD_ID = "UCr_iyUANcn9OX_yy9piYoLw"


def _raw_search_album(
    title: str,
    artist: str,
    browse_id: str,
    album_type: str = "Album",
    year: str = "1997",
    artist_id: str = RADIOHEAD_ID,
    thumbnails=None,
) -> dict:
    """A raw ytmusicapi album-search item.

    Note artists[0]: a type label with id=None - ytmusicapi puts that in
    front of the real artists.
    """
    return {
        "category": "Albums",
        "resultType": "album",
        "title": title,
        "type": album_type,
        "duration": None,
        "year": year,
        "artists": [
            {"name": album_type, "id": None},
            {"name": artist, "id": artist_id},
        ],
        "browseId": browse_id,
        "isExplicit": False,
        "thumbnails": list(ALBUM_THUMBS if thumbnails is None else thumbnails),
    }


def _raw_album_payload(title: str = "OK Computer", tracks=None) -> dict:
    """A raw ytmusicapi get_album() payload."""
    return {
        "title": title,
        "type": "Album",
        "thumbnails": list(ALBUM_THUMBS),
        "isExplicit": False,
        "description": "",
        "artists": [{"name": "Radiohead", "id": RADIOHEAD_ID}],
        "year": "1997",
        "trackCount": 3,
        "duration": "53 minutes",
        "audioPlaylistId": None,
        "tracks": list(tracks or []),
    }


def _raw_track(video_id: str, title: str, number: int, thumbnails=None) -> dict:
    return {
        "videoId": video_id,
        "title": title,
        "artists": [{"name": "Radiohead", "id": RADIOHEAD_ID}],
        "album": "OK Computer",
        "isExplicit": False,
        "videoType": "MUSIC_VIDEO_TYPE_ATV",
        "trackNumber": number,
        "duration": "4:48",
        "duration_seconds": 288,
        "thumbnails": thumbnails,
    }


class TestAlbumArtistNames(unittest.TestCase):
    """The type label ytmusicapi puts in front of the artists is removed."""

    def test_type_label_is_stripped(self):
        raw = [
            {"name": "Album", "id": None},
            {"name": "Radiohead", "id": RADIOHEAD_ID},
        ]
        self.assertEqual(_album_artist_names(raw), ["Radiohead"])

    def test_single_label_is_stripped(self):
        raw = [
            {"name": "Single", "id": None},
            {"name": "Radiohead", "id": RADIOHEAD_ID},
        ]
        self.assertEqual(_album_artist_names(raw), ["Radiohead"])

    def test_real_artists_are_kept(self):
        raw = [
            {"name": "Radiohead", "id": RADIOHEAD_ID},
            {"name": "Producer", "id": "UCproducer"},
        ]
        self.assertEqual(_album_artist_names(raw), ["Radiohead", "Producer"])

    def test_artist_without_id_is_kept_when_it_is_the_only_one(self):
        raw = [{"name": "Unknown Artist", "id": None}]
        self.assertEqual(_album_artist_names(raw), ["Unknown Artist"])

    def test_normalize_strips_diacritics_and_whitespace(self):
        self.assertEqual(_normalize_artist_name("Beyoncé"), "beyonce")
        self.assertEqual(_normalize_artist_name("  Radio   head "), "radiohead")
        self.assertEqual(_normalize_artist_name(""), "")


class TestAlbumSearchMapping(unittest.TestCase):
    """Mapping of a raw album-search item to the API shape."""

    def test_mapped_shape(self):
        mapped = _map_album_search_item(
            _raw_search_album("OK Computer", "Radiohead", "MPREb_yXhSI4FCUo6")
        )
        self.assertEqual(mapped["browseId"], "MPREb_yXhSI4FCUo6")
        self.assertEqual(mapped["title"], "OK Computer")
        self.assertEqual(mapped["artists"], ["Radiohead"])
        self.assertEqual(mapped["year"], "1997")
        self.assertEqual(mapped["type"], "Album")
        # Search results carry no track count.
        self.assertEqual(mapped["trackCount"], 0)

    def test_small_and_large_thumbnails_are_picked(self):
        mapped = _map_album_search_item(
            _raw_search_album("OK Computer", "Radiohead", "MPREb_yXhSI4FCUo6")
        )
        self.assertEqual(mapped["thumbnailSmall"]["width"], 120)
        self.assertEqual(mapped["thumbnailLarge"]["width"], 544)
        # All thumbnails are returned, ascending.
        self.assertEqual(
            [t["width"] for t in mapped["thumbnails"]], [60, 120, 226, 544]
        )

    def test_item_without_browse_id_is_skipped(self):
        raw = _raw_search_album("OK Computer", "Radiohead", "MPREb_yXhSI4FCUo6")
        raw.pop("browseId")
        self.assertIsNone(_map_album_search_item(raw))

    def test_missing_year_is_empty_string(self):
        raw = _raw_search_album("OK Computer", "Radiohead", "MPREb_1")
        raw.pop("year")
        mapped = _map_album_search_item(raw)
        self.assertEqual(mapped["year"], "")


class TestAlbumFiltering(unittest.TestCase):
    """Tribute albums are dropped; the shelf is never empty."""

    def _albums(self):
        return [
            _map_album_search_item(
                _raw_search_album("OK Computer", "Radiohead", "MPREb_1")
            ),
            _map_album_search_item(
                _raw_search_album(
                    "Guitar Tribute To Radiohead",
                    "Echoed Catalyst",
                    "MPREb_2",
                    artist_id="UCtOXb_VzVVnFIDX5_X-Tm0Q",
                )
            ),
            _map_album_search_item(
                _raw_search_album(
                    "No Surprises", "Radiohead", "MPREb_3", album_type="Single"
                )
            ),
        ]

    def test_tribute_albums_are_filtered_out(self):
        kept = _filter_and_sort_albums(self._albums(), "Radiohead", 10)
        self.assertEqual(
            [a["title"] for a in kept], ["OK Computer", "No Surprises"]
        )

    def test_album_type_comes_before_single(self):
        kept = _filter_and_sort_albums(self._albums(), "Radiohead", 10)
        self.assertEqual([a["type"] for a in kept], ["Album", "Single"])

    def test_fallback_keeps_results_when_nothing_matches(self):
        albums = [
            _map_album_search_item(
                _raw_search_album(
                    "Guitar Tribute To Radiohead",
                    "Echoed Catalyst",
                    "MPREb_2",
                    artist_id="UCtOXb_VzVVnFIDX5_X-Tm0Q",
                )
            )
        ]
        kept = _filter_and_sort_albums(albums, "Radiohead", 10)
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]["title"], "Guitar Tribute To Radiohead")

    def test_accented_artist_names_match(self):
        albums = [
            _map_album_search_item(
                _raw_search_album(
                    "Lemonade", "Beyoncé", "MPREb_3", artist_id="UCbeyonce"
                )
            ),
            _map_album_search_item(
                _raw_search_album(
                    "Lemonade Tribute", "Some Cover Band", "MPREb_4",
                    artist_id="UCcover",
                )
            ),
        ]
        kept = _filter_and_sort_albums(albums, "Beyonce", 10)
        self.assertEqual([a["title"] for a in kept], ["Lemonade"])

    def test_limit_caps_the_result(self):
        kept = _filter_and_sort_albums(self._albums(), "Radiohead", 1)
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]["title"], "OK Computer")


class TestAlbumDetailsMapping(unittest.TestCase):
    """Album details: album art fallback + track order."""

    def test_tracks_fall_back_to_album_art(self):
        data = _raw_album_payload(
            tracks=[
                _raw_track("v1", "Airbag", 1),
                _raw_track("v2", "Paranoid Android", 2),
            ]
        )
        album = _map_album_details(data, "MPREb_yXhSI4FCUo6")

        self.assertEqual(album["browseId"], "MPREb_yXhSI4FCUo6")
        self.assertEqual(album["title"], "OK Computer")
        self.assertEqual(album["artists"], ["Radiohead"])
        self.assertEqual(album["year"], "1997")
        self.assertEqual(album["type"], "Album")
        self.assertEqual(album["trackCount"], 3)

        for track in album["tracks"]:
            self.assertEqual(track["thumbnails"], album["thumbnails"])
            self.assertEqual(track["thumbnailSmall"]["width"], 120)
            self.assertEqual(track["thumbnailLarge"]["width"], 544)
            self.assertEqual(track["album"], "OK Computer")
            self.assertEqual(track["videoType"], "MUSIC_VIDEO_TYPE_ATV")
            self.assertEqual(track["durationSeconds"], 288)

    def test_track_order_is_preserved(self):
        data = _raw_album_payload(
            tracks=[
                _raw_track("v3", "Subterranean Homesick Alien", 3),
                _raw_track("v1", "Airbag", 1),
                _raw_track("v2", "Paranoid Android", 2),
            ]
        )
        album = _map_album_details(data, "MPREb_1")
        self.assertEqual(
            [t["title"] for t in album["tracks"]],
            [
                "Subterranean Homesick Alien",
                "Airbag",
                "Paranoid Android",
            ],
        )

    def test_track_with_own_thumbnails_keeps_them(self):
        own = [_thumb(60), _thumb(120)]
        data = _raw_album_payload(tracks=[_raw_track("v1", "Airbag", 1, own)])
        album = _map_album_details(data, "MPREb_1")
        self.assertEqual(album["tracks"][0]["thumbnails"], own)
        self.assertEqual(album["tracks"][0]["thumbnailSmall"]["width"], 120)

    def test_track_without_video_id_is_skipped(self):
        bad = _raw_track("v1", "Airbag", 1)
        bad["videoId"] = None
        data = _raw_album_payload(tracks=[bad, _raw_track("v2", "Karma Police", 2)])
        album = _map_album_details(data, "MPREb_1")
        self.assertEqual([t["title"] for t in album["tracks"]], ["Karma Police"])


class _FakeYT:
    """Stands in for ytmusicapi's YTMusic - no network."""

    def __init__(self, search_results=None, album_payload=None, error=None):
        self._search_results = search_results or []
        self._album_payload = album_payload
        self._error = error

    def search(self, query, filter=None, limit=None):
        if self._error:
            raise self._error
        return self._search_results

    def get_album(self, browse_id):
        if self._error:
            raise self._error
        return self._album_payload


def _client(fake_yt) -> YTMusicClient:
    """A YTMusicClient without touching the network in __init__."""
    client = YTMusicClient.__new__(YTMusicClient)
    client.yt = fake_yt
    return client


class TestAlbumClientMethods(unittest.TestCase):
    """The client methods glue the ytmusicapi calls to the mapping."""

    def test_search_albums_filters_and_sorts(self):
        fake = _FakeYT(
            search_results=[
                _raw_search_album("Guitar Tribute To Radiohead", "Echoed Catalyst",
                                  "MPREb_2", artist_id="UCtOX"),
                _raw_search_album("No Surprises", "Radiohead", "MPREb_3",
                                  album_type="Single"),
                _raw_search_album("OK Computer", "Radiohead", "MPREb_1"),
            ]
        )
        albums = _client(fake).search_albums("Radiohead", 10)
        self.assertEqual(
            [a["title"] for a in albums], ["OK Computer", "No Surprises"]
        )

    def test_search_albums_survives_a_ytmusicapi_error(self):
        fake = _FakeYT(error=RuntimeError("parser blew up"))
        self.assertEqual(_client(fake).search_albums("Radiohead", 10), [])

    def test_get_album_details_returns_none_on_error(self):
        fake = _FakeYT(error=RuntimeError("parser blew up"))
        self.assertIsNone(_client(fake).get_album_details("MPREb_1"))

    def test_get_album_details_returns_none_when_missing(self):
        fake = _FakeYT(album_payload=None)
        self.assertIsNone(_client(fake).get_album_details("MPREb_1"))

    def test_get_album_details_maps_the_payload(self):
        fake = _FakeYT(
            album_payload=_raw_album_payload(
                tracks=[_raw_track("v1", "Airbag", 1)]
            )
        )
        album = _client(fake).get_album_details("MPREb_yXhSI4FCUo6")
        self.assertEqual(album["browseId"], "MPREb_yXhSI4FCUo6")
        self.assertEqual(len(album["tracks"]), 1)
        self.assertEqual(album["tracks"][0]["title"], "Airbag")


if __name__ == "__main__":
    unittest.main(verbosity=2)
