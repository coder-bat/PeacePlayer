"""Refuse cache mutation unless a disposable server proves its instance identity."""
import json
import os
from pathlib import Path
import tempfile
from urllib.parse import urlsplit
from urllib.request import urlopen


def require_disposable_service():
    url = os.environ.get("PEACEPLAYER_TEST_BASE_URL", "").rstrip("/")
    parts = urlsplit(url)
    raw_root = os.environ.get("PEACEPLAYER_TEST_DATA_DIR", "")
    instance = os.environ.get("PEACEPLAYER_TEST_INSTANCE_ID", "")
    if (os.environ.get("PEACEPLAYER_RUN_LIVE_TESTS") != "1" or not raw_root or not instance
            or not os.environ.get("PEACEPLAYER_TEST_SESSION_TOKEN")
            or parts.scheme != "http" or parts.hostname not in ("127.0.0.1", "localhost", "::1")
            or not parts.port or parts.port == 8181 or parts.path or parts.username):
        raise RuntimeError("Live tests require explicit opt-in, loopback disposable port, temporary data root, instance ID and test session token.")
    root = Path(raw_root).resolve()
    temp_root = Path(tempfile.gettempdir()).resolve()
    if not root.is_relative_to(temp_root) or root == temp_root:
        raise RuntimeError("Live test data must be inside a dedicated temporary directory.")
    marker = root / ".peaceplayer-test-instance"
    if not marker.is_file() or marker.read_text().strip() != instance:
        raise RuntimeError("Disposable data marker does not match the test instance.")
    with urlopen(url + "/health", timeout=3) as response:
        health = json.load(response)
    if health.get("testInstanceId") != instance:
        raise RuntimeError("Server did not prove it owns the disposable test instance; refusing cache changes.")
    return url, root
