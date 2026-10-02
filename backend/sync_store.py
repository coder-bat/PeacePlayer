"""Versioned full-snapshot storage. One process owns all reads and conditional writes."""
from __future__ import annotations

import collections
import hashlib
import json
import logging
import os
from pathlib import Path
import tempfile
import threading
import time
import uuid
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

logger = logging.getLogger(__name__)
_WRITE_LOCK = threading.RLock()
BACKUP_RETENTION = 5
OPERATION_RETENTION = 32


class SyncRecoveryError(Exception):
    """Existing data cannot be read or committed safely; never substitute emptiness."""


class StaleRevision(Exception):
    pass


class OperationConflict(Exception):
    pass


class SmartCriteria(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    type: Literal["Recently Added", "Recently Played", "Most Played", "Liked Songs", "Downloaded", "Never Played"]
    limit: int | None = Field(default=None, ge=0)
    sortBy: Literal["Default", "Recently Added", "Alphabetical", "Artist"]


class Playlist(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", allow_inf_nan=False)
    id: str
    name: str
    trackIds: list[str]
    modifiedAt: float
    createdAt: float | None = None
    description: str | None = None
    isSmart: bool | None = None
    smartCriteria: SmartCriteria | None = None
    artworkSeed: int | None = None
    thumbnailURL: str | None = None

    @model_validator(mode="after")
    def valid(self):
        uuid.UUID(self.id)
        if any(not value for value in self.trackIds):
            raise ValueError("empty track identity")
        return self


class Thumbnail(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    url: str
    width: int = Field(ge=0)
    height: int = Field(ge=0)


class Track(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    videoId: str = Field(min_length=1)
    title: str
    artists: list[str]
    album: str
    durationSeconds: int = Field(ge=0)
    thumbnails: list[Thumbnail]
    thumbnailSmall: Thumbnail | None = None
    thumbnailLarge: Thumbnail | None = None
    isExplicit: bool
    videoType: str


class HistoryEvent(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", allow_inf_nan=False)
    id: str = Field(min_length=1)
    videoId: str = Field(min_length=1)
    playedAt: float
    progress: float = Field(ge=0, le=1)
    completed: bool


class Snapshot(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    playlists: list[Playlist]
    favorites: list[str]
    favoriteArtists: list[str]
    tracks: list[Track]
    history: list[HistoryEvent]

    @model_validator(mode="after")
    def unique_identities(self):
        for values in [[p.id.lower() for p in self.playlists], [t.videoId for t in self.tracks],
                       [h.id for h in self.history]]:
            if len(values) != len(set(values)):
                raise ValueError("duplicate record identity")
        if any(not value for value in self.favorites):
            raise ValueError("empty favorite identity")
        referenced = set(self.favorites) | {event.videoId for event in self.history}
        for playlist in self.playlists:
            referenced.update(playlist.trackIds)
        if not referenced.issubset({track.videoId for track in self.tracks}):
            raise ValueError("referenced track metadata missing")
        return self


class Upload(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    schemaVersion: Literal[2]
    baseRevision: int = Field(ge=0)
    operationId: str = Field(min_length=1, max_length=128)
    snapshot: Snapshot


def empty_snapshot() -> dict:
    return {key: [] for key in ("playlists", "favorites", "favoriteArtists", "tracks", "history")}


def _canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def _metadata_cache(directory: Path) -> dict:
    """Load real per-track metadata hydrated out of band by
    scripts/hydrate-sync-metadata.py.

    The legacy blob predates stored track metadata, so the migration has to
    invent *something* for every referenced videoId. Inventing "Recovered
    track" for all of them is correct but useless, and those placeholders then
    overwrite the user's real titles on the client. The cache lets the same
    migration produce real credits once they have been fetched, without making
    the request path talk to YouTube.
    """
    path = Path(directory) / "track-metadata.json"
    if not path.is_file():
        return {}
    try:
        loaded = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def _legacy_snapshot(blob: dict, cache: dict | None = None) -> dict:
    snapshot = {key: blob.get(key, []) for key in empty_snapshot()}
    # Legacy events had no IDs/completed flag; expose stable IDs for every restore.
    #
    # (videoId, playedAt) is NOT unique in real data. The same track appears at
    # the same second more than once, so a digest of just those two fields is
    # identical for both events and Snapshot.unique_identities rejects the whole
    # snapshot -- which surfaced as a hard 503 on GET /sync/v2 and left the
    # client with an unusable backup. Fold in a per-group occurrence counter so
    # the derivation stays deterministic and lossless without inventing distinct
    # events out of nothing.
    seen: collections.Counter = collections.Counter()
    history = []
    for event in snapshot["history"]:
        micros = int(float(event["playedAt"]) * 1_000_000)
        key = (event["videoId"], micros)
        occurrence = seen[key]
        seen[key] += 1
        history.append(dict(
            event,
            id=event.get("id") or str(uuid.UUID(bytes=hashlib.sha256(
                f"history|{key[0]}|{key[1]}|{occurrence}".encode()).digest()[:16])),
            completed=event.get("completed", False),
        ))
    snapshot["history"] = history
    ids = set(snapshot["favorites"])
    ids.update(event["videoId"] for event in snapshot["history"])
    for playlist in snapshot["playlists"]:
        ids.update(playlist["trackIds"])
    known = {track["videoId"] for track in snapshot["tracks"]}
    hydrated = cache or {}
    # Prefer real metadata when scripts/hydrate-sync-metadata.py has fetched
    # it; fall back to the self-identifying placeholder so an unhydrated id is
    # still obviously not a real title to the client.
    for video_id in sorted(ids - known):
        meta = hydrated.get(video_id) or {}
        snapshot["tracks"].append(Track(
            videoId=video_id,
            title=meta.get("title") or "Recovered track",
            artists=meta.get("artists") or [],
            album=meta.get("album") or "",
            durationSeconds=int(meta.get("durationSeconds") or 0),
            thumbnails=meta.get("thumbnails") or [],
            isExplicit=bool(meta.get("isExplicit", False)),
            videoType=meta.get("videoType") or "",
        ))
    return Snapshot.model_validate(snapshot).model_dump()


class SyncStore:
    def __init__(self, directory: Path):
        self.directory = directory

    def _path(self, user_id: str) -> Path:
        # JWT subjects are UUIDs from our user store; refuse paths even if a caller errs.
        return self.directory / f"{uuid.UUID(user_id)}.json"

    def _read(self, user_id: str) -> tuple[dict, dict | None]:
        path = self._path(user_id)
        try:
            raw = path.read_bytes()
        except FileNotFoundError:
            return dict(schemaVersion=2, revision=0, exists=False, snapshot=empty_snapshot()), None
        except OSError as exc:
            raise SyncRecoveryError("sync_snapshot_unreadable") from exc
        try:
            blob = json.loads(raw)
            if not isinstance(blob, dict):
                raise ValueError("snapshot must be object")
            if "schemaVersion" in blob:
                if blob["schemaVersion"] != 2 or type(blob.get("revision")) is not int or blob["revision"] < 1:
                    raise ValueError("unsupported or invalid stored schema")
                snapshot = Snapshot.model_validate(blob["snapshot"]).model_dump()
                receipts = blob.get("operations")
                if not isinstance(receipts, list) or any(not isinstance(receipt, dict) or
                        not isinstance(receipt.get("id"), str) or not isinstance(receipt.get("digest"), str)
                        for receipt in receipts):
                    raise ValueError("invalid operation receipts")
                return dict(schemaVersion=2, revision=blob["revision"], exists=True, snapshot=snapshot), blob
            return dict(schemaVersion=2, revision=0, exists=True,
                        snapshot=_legacy_snapshot(blob, _metadata_cache(self.directory)),
                        migratedFromSchemaVersion=1), blob
        except (ValueError, TypeError, KeyError, AttributeError) as exc:
            raise SyncRecoveryError("sync_snapshot_corrupt") from exc

    def read(self, user_id: str) -> dict:
        with _WRITE_LOCK:
            return self._read(user_id)[0]

    @staticmethod
    def _atomic_write(path: Path, data: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor, temporary = tempfile.mkstemp(prefix=".sync-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def write(self, user_id: str, upload: Upload) -> dict:
        snapshot = upload.snapshot.model_dump()
        digest = hashlib.sha256(_canonical(snapshot)).hexdigest()
        with _WRITE_LOCK:
            envelope, previous = self._read(user_id)
            receipts = previous.get("operations", []) if previous else []
            for receipt in receipts:
                if receipt["id"] != upload.operationId:
                    continue
                if receipt["digest"] != digest:
                    raise OperationConflict("sync_operation_reused")
                # Return current state, including later writes, without reapplying this operation.
                return envelope
            if upload.baseRevision != envelope["revision"]:
                raise StaleRevision("sync_stale_revision")
            stored = dict(schemaVersion=2, revision=envelope["revision"] + 1, snapshot=snapshot,
                          operations=(receipts + [{"id": upload.operationId, "digest": digest}])[-OPERATION_RETENTION:],
                          uploadedAt=int(time.time()))
            path = self._path(user_id)
            backup_dir = self.directory / "backups" / str(uuid.UUID(user_id))
            try:
                if previous is not None:
                    self._atomic_write(backup_dir / f"revision-{envelope['revision']:020d}.json", path.read_bytes())
                self._atomic_write(path, _canonical(stored))
            except OSError as exc:
                raise SyncRecoveryError("sync_snapshot_write_failed") from exc
            # Retention cleanup cannot turn a committed write into a reported failure.
            for old in sorted(backup_dir.glob("revision-*.json"))[:-BACKUP_RETENTION]:
                try:
                    old.unlink()
                except OSError:
                    logger.warning("Sync backup retention cleanup deferred")
            return dict(schemaVersion=2, revision=stored["revision"], exists=True, snapshot=snapshot)
