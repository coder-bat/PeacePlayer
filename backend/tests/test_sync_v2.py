"""Atomic snapshot, migration and HTTP contracts using only temporary fixture state."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import secrets
import uuid

import httpx
import pytest
from pydantic import ValidationError

from sync_store import BACKUP_RETENTION, OperationConflict, StaleRevision, SyncRecoveryError, SyncStore, Upload

FIXTURES = Path(__file__).resolve().parents[2] / "shared/sync-fixtures"


@pytest.fixture
def upload():
    return Upload.model_validate(json.loads((FIXTURES / "populated-upload.json").read_text()))


@pytest.fixture
def store(tmp_path):
    return SyncStore(tmp_path), str(uuid.uuid4())


def test_empty_account_and_roundtrip(store, upload):
    storage, user = store
    assert storage.read(user) == json.loads((FIXTURES / "empty-account.json").read_text())
    result = storage.write(user, upload)
    assert result["revision"] == 1
    assert result["exists"]
    assert storage.read(user) == result
    assert result["snapshot"] == upload.snapshot.model_dump()
    assert result == json.loads((FIXTURES / "server-envelope.json").read_text())


def test_stale_and_idempotent_writes_cannot_replace_newer_data(store, upload):
    storage, user = store
    first = storage.write(user, upload)
    assert storage.write(user, upload) == first
    newer = upload.model_copy(deep=True)
    newer.baseRevision = 1
    newer.operationId = "next-operation"
    newer.snapshot.favorites = []
    result = storage.write(user, newer)
    before = storage._path(user).read_bytes()
    # A lost response retried after another writer must never replay older data.
    assert storage.write(user, upload) == result
    assert storage._path(user).read_bytes() == before
    stale = upload.model_copy(update={"operationId": "stale-operation"})
    with pytest.raises(StaleRevision):
        storage.write(user, stale)
    reused = upload.model_copy(deep=True)
    reused.snapshot.favorites = []
    with pytest.raises(OperationConflict):
        storage.write(user, reused)
    assert storage._path(user).read_bytes() == before


def test_concurrent_same_revision_allows_one_writer(store, upload):
    storage, user = store
    def write(index):
        request = upload.model_copy(update={"operationId": f"concurrent-{index}"})
        try:
            return storage.write(user, request)["revision"]
        except StaleRevision:
            return "stale"
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(write, range(8)))
    assert results.count(1) == 1
    assert results.count("stale") == 7
    assert storage.read(user)["revision"] == 1


def test_legacy_metadata_migration_is_readonly_and_stable(store, upload):
    storage, user = store
    original = (FIXTURES / "legacy-snapshot.json").read_bytes()
    storage._path(user).write_bytes(original)
    migrated = storage.read(user)
    assert migrated["revision"] == 0 and migrated["exists"]
    assert migrated["migratedFromSchemaVersion"] == 1
    assert migrated == storage.read(user)
    assert migrated == json.loads((FIXTURES / "migrated-envelope.json").read_text())
    assert storage._path(user).read_bytes() == original
    assert migrated["snapshot"]["tracks"][0]["title"] == "Recovered track"
    assert migrated["snapshot"]["history"][0]["completed"] is False
    write = Upload(schemaVersion=2, baseRevision=0, operationId="migrate", snapshot=migrated["snapshot"])
    assert storage.write(user, write)["revision"] == 1
    backups = list((storage.directory / "backups" / user).glob("*.json"))
    assert len(backups) == 1 and backups[0].read_bytes() == original


def test_legacy_history_with_duplicate_timestamp_pairs_still_migrates(store):
    # Real accounts contain the same track played at the same second more than
    # once. Deriving an id from (videoId, playedAt) alone made those events
    # collide, which failed Snapshot.unique_identities and turned every
    # GET /sync/v2 into a 503 -- an unusable backup for the whole account.
    storage, user = store
    played = 1783119479.0
    blob = {
        "playlists": [],
        "favorites": ["dup-track"],
        "favoriteArtists": [],
        "history": [
            {"videoId": "dup-track", "playedAt": played, "progress": 1.0},
            {"videoId": "dup-track", "playedAt": played, "progress": 1.0},
            {"videoId": "dup-track", "playedAt": played, "progress": 1.0},
            {"videoId": "other-track", "playedAt": played, "progress": 0.5},
        ],
    }
    storage._path(user).write_bytes(json.dumps(blob).encode())

    migrated = storage.read(user)
    history = migrated["snapshot"]["history"]
    assert len(history) == 4, "no event may be dropped or invented"
    ids = [event["id"] for event in history]
    assert len(set(ids)) == 4, f"ids collided: {ids}"
    # The three identical listens stay distinguishable but deterministic.
    assert ids[0] != ids[1] != ids[2]
    assert migrated == storage.read(user)
    # Referenced tracks are still backfilled, so the reference check passes.
    assert {track["videoId"] for track in migrated["snapshot"]["tracks"]} == {"dup-track", "other-track"}


@pytest.mark.parametrize("raw", [b"{broken", b"[]", b'{"history":false}', b'{"schemaVersion":99}',
                                    b'{"schemaVersion":2,"revision":0,"snapshot":{}}'])
def test_corrupt_is_never_treated_as_missing(store, upload, raw):
    storage, user = store
    storage._path(user).write_bytes(raw)
    with pytest.raises(SyncRecoveryError):
        storage.read(user)
    with pytest.raises(SyncRecoveryError):
        storage.write(user, upload)
    assert storage._path(user).read_bytes() == raw


def test_failed_atomic_replace_preserves_previous_and_retry(store, upload, monkeypatch):
    import sync_store
    storage, user = store
    storage.write(user, upload)
    before = storage._path(user).read_bytes()
    next_upload = upload.model_copy(update={"baseRevision": 1, "operationId": "retry"})
    real_replace = sync_store.os.replace
    def fail_primary(source, target):
        if Path(target) == storage._path(user):
            raise OSError("fixture interrupted write")
        return real_replace(source, target)
    with monkeypatch.context() as patch:
        patch.setattr(sync_store.os, "replace", fail_primary)
        with pytest.raises(SyncRecoveryError):
            storage.write(user, next_upload)
    assert storage._path(user).read_bytes() == before
    assert not list(storage.directory.glob(".sync-*"))
    assert storage.write(user, next_upload)["revision"] == 2


def test_bounded_backups_and_private_permissions(store, upload):
    storage, user = store
    for revision in range(10):
        request = upload.model_copy(update={"baseRevision": revision, "operationId": f"op-{revision}"})
        storage.write(user, request)
    backups = list((storage.directory / "backups" / user).glob("*.json"))
    assert len(backups) == BACKUP_RETENTION
    assert not storage._path(user).stat().st_mode & 0o077
    assert all(not path.stat().st_mode & 0o077 for path in backups)


def test_unreadable_snapshot_cannot_be_overwritten(store, upload, monkeypatch):
    storage, user = store
    storage.write(user, upload)
    original_read = Path.read_bytes
    def unreadable(path):
        if path == storage._path(user):
            raise PermissionError("fixture unreadable")
        return original_read(path)
    monkeypatch.setattr(Path, "read_bytes", unreadable)
    with pytest.raises(SyncRecoveryError, match="unreadable"):
        storage.read(user)
    with pytest.raises(SyncRecoveryError, match="unreadable"):
        storage.write(user, upload)


def test_failed_backup_stops_primary_write(store, upload, monkeypatch):
    storage, user = store
    storage.write(user, upload)
    before = storage._path(user).read_bytes()
    def fail_backup(*args):
        raise OSError("fixture backup failure")
    monkeypatch.setattr(storage, "_atomic_write", fail_backup)
    with pytest.raises(SyncRecoveryError, match="write_failed"):
        storage.write(user, upload.model_copy(update={"baseRevision": 1, "operationId": "backup-failure"}))
    assert storage._path(user).read_bytes() == before


@pytest.mark.parametrize("mutation", ["missing-array", "missing-track", "bad-playlist", "nan", "duplicate-event", "bad-duration"])
def test_schema_rejects_unsafe_payload(upload, mutation):
    raw = upload.model_dump()
    snapshot = raw["snapshot"]
    if mutation == "missing-array": del snapshot["history"]
    elif mutation == "missing-track": snapshot["tracks"] = []
    elif mutation == "bad-playlist": snapshot["playlists"][0]["id"] = "../../escape"
    elif mutation == "nan": snapshot["history"][0]["progress"] = float("nan")
    elif mutation == "duplicate-event": snapshot["history"] *= 2
    elif mutation == "bad-duration": snapshot["tracks"][0]["durationSeconds"] = -1
    with pytest.raises(ValidationError):
        Upload.model_validate(raw)


def test_http_contracts_and_legacy_reads(tmp_path, monkeypatch, upload):
    import apple_auth
    import server
    monkeypatch.setattr(apple_auth, "SYNC_DIR", tmp_path / "sync")
    monkeypatch.setattr(apple_auth, "USERS_DIR", tmp_path / "users")
    apple_auth.USERS_DIR.mkdir()
    monkeypatch.setattr(apple_auth, "SESSION_JWT_SECRET", secrets.token_urlsafe(48))
    monkeypatch.setattr(server.limiter, "enabled", False)
    user, _ = apple_auth.get_or_create_user("fixture-http-account", {})
    token = apple_auth.mint_session_jwt(user["user_id"], "fixture-http-account")
    async def scenario():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=server.app), base_url="http://test") as client:
            assert (await client.get("/sync/v2")).status_code == 401
            headers = {"Authorization": "Bearer " + token}
            assert (await client.get("/sync/v2", headers=headers)).json()["exists"] is False
            result = await client.post("/sync/v2", headers=headers, json=upload.model_dump())
            assert result.status_code == 200 and result.json()["revision"] == 1
            read = await client.get("/sync/download", headers=headers)
            assert read.status_code == 200 and read.json()["favorites"] == ["fixture-track"]
            assert (await client.post("/sync/upload", headers=headers, json={})).status_code == 426
            raw = upload.model_dump();raw["operationId"] = "stale"
            assert (await client.post("/sync/v2", headers=headers, json=raw)).status_code == 409
            assert (await client.post("/sync/v2", headers=headers, json={})).status_code == 422
            apple_auth.sync_path(user["user_id"]).write_text("broken")
            assert (await client.get("/sync/v2", headers=headers)).status_code == 503
            assert (await client.get("/sync/download", headers=headers)).status_code == 503
            assert (await client.post("/sync/v2", headers=headers, json=upload.model_dump())).status_code == 503
            assert apple_auth.sync_path(user["user_id"]).read_text() == "broken"
    asyncio.run(scenario())
