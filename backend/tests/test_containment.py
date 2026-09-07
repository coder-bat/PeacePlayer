"""Offline credential/legacy-sync contracts, with no production state or lifespan."""
import asyncio
import importlib
import logging
import os
from pathlib import Path
import secrets
import sys
import subprocess

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@pytest.fixture
def isolated_server(tmp_path, monkeypatch):
    # All configuration is installed before the first application import.
    monkeypatch.setenv("PEACEPLAYER_LOAD_DOTENV", "0")
    monkeypatch.setenv("PEACEPLAYER_JWT_SECRET", secrets.token_urlsafe(48))
    monkeypatch.setenv("PEACEPLAYER_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("PREWARM_ENABLED", "false")
    monkeypatch.setenv("HLS_CLEANUP_ENABLED", "false")
    server = importlib.import_module("server")
    auth = importlib.import_module("apple_auth")
    monkeypatch.setattr(auth, "SESSION_JWT_SECRET", secrets.token_urlsafe(48))
    for attr, name in [("USERS_DIR", "users"), ("SYNC_DIR", "sync")]:
        directory = tmp_path / name
        directory.mkdir(exist_ok=True)
        monkeypatch.setattr(auth, attr, directory)
    monkeypatch.setattr(server.limiter, "enabled", False)
    return server, auth


def test_signin_then_legacy_empty_upload_preserves_backup(isolated_server, monkeypatch):
    server, auth = isolated_server
    user, _ = auth.get_or_create_user("fixture-apple-sub", {})
    original = b'{"favorites":["fixture-track"],"playlists":[],"history":[]}'
    auth.sync_path(user["user_id"]).write_bytes(original)
    monkeypatch.setattr(server, "verify_apple_identity_token", lambda _: {"sub": "fixture-apple-sub"})

    async def scenario():
        transport = httpx.ASGITransport(app=server.app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            signin = await client.post("/auth/apple", json={"identityToken": "fixture"})
            assert signin.status_code == 200
            headers = {"Authorization": "Bearer " + signin.json()["sessionToken"]}
            upload = await client.post("/sync/upload", headers=headers, json={})
            assert upload.status_code == 426
            assert upload.json()["detail"] == "legacy_sync_upgrade_required"
            assert auth.sync_path(user["user_id"]).read_bytes() == original
            populated = await client.post("/sync/upload", headers=headers,
                                          json={"favorites": ["other-track"], "history": [{"videoId": "other-track"}]})
            assert populated.status_code == 426
            assert auth.sync_path(user["user_id"]).read_bytes() == original
            download = await client.get("/sync/download", headers=headers)
            assert download.status_code == 200
            assert download.json()["favorites"] == ["fixture-track"]
            unauthenticated = await client.post("/sync/upload", json={})
            assert unauthenticated.status_code == 401
    asyncio.run(scenario())


def test_rotated_key_rejects_old_sessions(isolated_server, monkeypatch):
    server, auth = isolated_server
    user, _ = auth.get_or_create_user("fixture-sub", {})
    old = auth.mint_session_jwt(user["user_id"], "fixture-sub")
    assert auth.verify_session_jwt(old)
    monkeypatch.setattr(auth, "SESSION_JWT_SECRET", secrets.token_urlsafe(48))
    assert auth.verify_session_jwt(old) is None
    from types import SimpleNamespace
    monkeypatch.setattr(server, "get_client", lambda: SimpleNamespace(get_stream_url=lambda _: None))
    fresh = auth.mint_session_jwt(user["user_id"], "fixture-sub")
    assert auth.verify_session_jwt(fresh)["sub"] == user["user_id"]

    async def scenario():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=server.app), base_url="http://test") as client:
            assert (await client.get("/sync/download", headers={"Authorization": "Bearer " + old})).status_code == 401
            assert (await client.get("/audio/missing.m4a", params={"token": old})).status_code == 401
            assert (await client.get("/sync/download", headers={"Authorization": "Bearer " + fresh})).status_code == 200
            assert (await client.get("/audio/missing.m4a", params={"token": fresh})).status_code == 404
    asyncio.run(scenario())


@pytest.mark.parametrize("secret", [None, "too-short"])
def test_missing_or_weak_secret_fails_closed(tmp_path, secret):
    environment = dict(os.environ, PEACEPLAYER_LOAD_DOTENV="0", PEACEPLAYER_DATA_DIR=str(tmp_path))
    environment.pop("PEACEPLAYER_JWT_SECRET", None)
    if secret:
        environment["PEACEPLAYER_JWT_SECRET"] = secret
    process = subprocess.run([sys.executable, "-c", "import apple_auth"], env=environment,
                             cwd=Path(__file__).resolve().parents[1], capture_output=True, text=True)
    assert process.returncode != 0
    assert "PEACEPLAYER_JWT_SECRET" in process.stderr


def test_access_and_exception_logs_redact_credentials(isolated_server):
    server, auth = isolated_server
    from log_redaction import redact_sensitive
    from uvicorn.logging import AccessFormatter
    token = auth.mint_session_jwt("fixture-user", "fixture-sub")
    logger = logging.getLogger("uvicorn.access")
    record = logger.makeRecord(logger.name, logging.INFO, "", 0, '%s - "%s %s HTTP/%s" %d',
                               ("127.0.0.1", "GET", f"/fast/track.mp4?token={token}&x=1", "1.1", 200), None)
    formatted = AccessFormatter().format(record)
    assert token not in formatted
    assert "token=[REDACTED]&x=1" in formatted
    try:
        raise ValueError(f"Authorization: Bearer {token}")
    except ValueError:
        record = logger.makeRecord("server", logging.ERROR, "", 0, "failed", (), sys.exc_info())
    assert token not in server.JSONFormatter().format(record)
    assert token not in logging.Formatter().format(record)
    assert token not in redact_sensitive(f"JWT={token} Authorization: Bearer {token}")
    assert redact_sensitive("/fast/a?%74oken=secret%2Fencoded&x=1") == "/fast/a?%74oken=[REDACTED]&x=1"
