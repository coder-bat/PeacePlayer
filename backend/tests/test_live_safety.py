"""Verify destructive integration checks refuse ordinary service/data defaults."""
import importlib.util
from pathlib import Path
import runpy
import pytest

LIVE = Path(__file__).parent / "live"
spec = importlib.util.spec_from_file_location("live_support", LIVE / "live_support.py")
live_support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live_support)


def test_live_harness_refuses_unconfigured_service(monkeypatch):
    monkeypatch.delenv("PEACEPLAYER_RUN_LIVE_TESTS", raising=False)
    with pytest.raises(RuntimeError, match="explicit opt-in"):
        live_support.require_disposable_service()


def test_live_harness_refuses_ordinary_port(monkeypatch, tmp_path):
    for name, value in {"PEACEPLAYER_RUN_LIVE_TESTS": "1", "PEACEPLAYER_TEST_BASE_URL": "http://localhost:8181",
                        "PEACEPLAYER_TEST_DATA_DIR": str(tmp_path), "PEACEPLAYER_TEST_INSTANCE_ID": "fixture",
                        "PEACEPLAYER_TEST_SESSION_TOKEN": "fixture"}.items():
        monkeypatch.setenv(name, value)
    with pytest.raises(RuntimeError, match="explicit opt-in"):
        live_support.require_disposable_service()


def test_live_recorded_failure_raises_assertion(monkeypatch):
    monkeypatch.syspath_prepend(str(LIVE))
    namespace = runpy.run_path(str(LIVE / "test_hls_live.py"), run_name="isolated_harness_contract")
    with pytest.raises(AssertionError, match="fixture failure"):
        namespace["TestStats"]().record("fixture failure", False)
