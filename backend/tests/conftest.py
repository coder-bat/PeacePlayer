"""Offline defaults established before test modules can import application code."""
import os
from pathlib import Path
import secrets
import sys
import tempfile

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
_isolated_root = tempfile.TemporaryDirectory(prefix="peaceplayer-pytest-")
os.environ["PEACEPLAYER_LOAD_DOTENV"] = "0"
os.environ["PEACEPLAYER_DATA_DIR"] = str(Path(_isolated_root.name) / "data")
os.environ["PEACEPLAYER_LIBRARY_DIR"] = str(Path(_isolated_root.name) / "library")
os.environ["PEACEPLAYER_OAUTH_FILE"] = str(Path(_isolated_root.name) / "oauth.json")
os.environ["PEACEPLAYER_JWT_SECRET"] = secrets.token_urlsafe(48)
os.environ["PREWARM_ENABLED"] = "false"
os.environ["HLS_CLEANUP_ENABLED"] = "false"


def pytest_sessionfinish(session, exitstatus):
    _isolated_root.cleanup()


@pytest.fixture(autouse=True)
def deny_external_network(monkeypatch, request):
    if request.node.get_closest_marker("live"):
        return

    def denied(*args, **kwargs):
        raise AssertionError("Offline tests cannot open network connections; inject a fake provider/transport.")

    import socket
    monkeypatch.setattr(socket.socket, "connect", denied)
    monkeypatch.setattr(socket.socket, "connect_ex", denied)
    monkeypatch.setattr(socket, "create_connection", denied)
