#!/usr/bin/env python3
"""Hydrate real track metadata for every videoId referenced by a legacy sync blob.

The legacy blob predates stored track metadata, so sync v2's migration has to
invent an entry for each referenced videoId. Without this script those
invented entries are titled "Recovered track" with no artist, duration or
artwork, and the client writes them over whatever real metadata it had.

This runs out of band and writes a cache that `_legacy_snapshot` consults, so
the request path never talks to YouTube for this. It is resumable: ids already
in the cache are skipped, and ids that fail are retried on the next run.

Usage:
    python3 scripts/hydrate-sync-metadata.py [--delay 0.4] [--limit N]

Run it with the same environment the service uses (PEACEPLAYER_DATA_DIR etc),
otherwise it will read a different sync directory than the one being served.
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

os.environ.setdefault("PEACEPLAYER_LOAD_DOTENV", "1")


def referenced_ids(blob: dict) -> set:
    snapshot = blob.get("snapshot", blob)
    ids = set(snapshot.get("favorites") or [])
    ids.update(event["videoId"] for event in (snapshot.get("history") or []) if event.get("videoId"))
    for playlist in (snapshot.get("playlists") or []):
        ids.update(playlist.get("trackIds") or [])
    return {i for i in ids if i}


def song_to_metadata(song: dict) -> dict:
    video_details = song.get("videoDetails") or {}
    thumbnails = [
        {"url": t.get("url", ""), "width": int(t.get("width", 0)), "height": int(t.get("height", 0))}
        for t in (video_details.get("thumbnails") or [])
        if t.get("url")
    ]
    artists = [a.get("name", "") for a in (video_details.get("author") or {}).get("artists", []) if a.get("name")]
    if not artists and video_details.get("author"):
        artists = [video_details["author"]]
    duration = video_details.get("lengthSeconds")
    return {
        "title": video_details.get("title") or "",
        "artists": artists,
        "album": ((video_details.get("album") or {}).get("name") or ""),
        "durationSeconds": int(duration) if str(duration or "").isdigit() else 0,
        "thumbnails": thumbnails,
        "isExplicit": bool(video_details.get("musicVideoType") == "MUSIC_VIDEO_TYPE_ATV"),
        "videoType": video_details.get("musicVideoType") or "",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delay", type=float, default=0.4,
                        help="seconds between lookups; be polite to YouTube")
    parser.add_argument("--limit", type=int, default=0, help="stop after N new lookups")
    args = parser.parse_args()

    from runtime_config import settings
    from ytm_client import get_client

    sync_dir = Path(settings.sync_dir)
    cache_path = sync_dir / "track-metadata.json"
    cache = {}
    if cache_path.is_file():
        try:
            cache = json.loads(cache_path.read_text())
        except ValueError:
            print("! existing cache is unreadable; starting fresh")
    print(f"cache: {cache_path} ({len(cache)} entries)")

    wanted = set()
    blobs = 0
    for path in sorted(sync_dir.glob("*.json")):
        if path.name == cache_path.name:
            continue
        try:
            wanted |= referenced_ids(json.loads(path.read_text()))
        except (OSError, ValueError):
            print(f"! skipping unreadable {path.name}")
            continue
        blobs += 1

    pending = sorted(wanted - set(cache))
    print(f"{blobs} blob(s) reference {len(wanted)} track(s); {len(pending)} need hydration")

    if not pending:
        print("nothing to do")
        return 0

    client = get_client()
    done = failed = 0
    for index, video_id in enumerate(pending, 1):
        if args.limit and done + failed >= args.limit:
            print(f"! stopping at --limit {args.limit}")
            break
        try:
            song = client.yt.get_song(video_id)
            meta = song_to_metadata(song or {})
            if not meta["title"]:
                raise ValueError("no title returned")
            cache[video_id] = meta
            done += 1
            if done % 10 == 0 or done == 1:
                print(f"  [{index}/{len(pending)}] {done} hydrated, {failed} failed  e.g. {meta['title'][:40]!r}")
        except Exception as exc:
            failed += 1
            print(f"  [{index}/{len(pending)}] ! {video_id}: {str(exc)[:70]}")
        # Persist as we go so a crash or Ctrl-C does not lose the work.
        cache_path.write_text(json.dumps(cache, indent=1, sort_keys=True))
        time.sleep(args.delay)

    print(f"\ndone: {done} hydrated, {failed} failed, {len(cache)} total in cache")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
