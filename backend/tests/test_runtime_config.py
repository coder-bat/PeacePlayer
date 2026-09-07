from pathlib import Path
import os
import subprocess
import sys

import pytest
from runtime_config import RuntimeSettings


def test_paths_follow_selected_data_root(tmp_path):
    settings = RuntimeSettings.from_env({"PEACEPLAYER_DATA_DIR": str(tmp_path / "different checkout"),
                                        "PEACEPLAYER_LIBRARY_DIR": str(tmp_path / "library")})
    assert settings.audio_cache_dir == tmp_path / "different checkout" / "audio_cache"
    assert settings.users_dir.parent == settings.sync_dir.parent == settings.hls_dir.parent
    assert not settings.data_dir.exists()  # Reading config never mutates storage.
    assert settings.ytdlp_command == (sys.executable, "-m", "yt_dlp")


def test_missing_binary_has_actionable_error(tmp_path):
    settings = RuntimeSettings.from_env({"FFMPEG_BIN": str(tmp_path / "missing"), "PATH": ""})
    with pytest.raises(RuntimeError, match="FFMPEG_BIN"):
        settings.validate()


def test_explicit_binary_overrides(tmp_path):
    tool = tmp_path / "fake tool"
    tool.write_text("#!/bin/sh\nexit 0\n")
    tool.chmod(0o700)
    settings = RuntimeSettings.from_env({"FFMPEG_BIN": str(tool), "DENO_BIN": str(tool)})
    settings.validate()


def test_preflight_is_offline_and_uses_temporary_storage(tmp_path):
    env = dict(os.environ, PEACEPLAYER_DATA_DIR=str(tmp_path / "data"),
               PEACEPLAYER_LIBRARY_DIR=str(tmp_path / "library"),
               PEACEPLAYER_LOAD_DOTENV="0", PREWARM_ENABLED="false", HLS_CLEANUP_ENABLED="false")
    backend = Path(__file__).resolve().parents[1]
    code = "import socket,runpy,sys; socket.socket.connect=lambda *a,**k: (_ for _ in ()).throw(AssertionError('network forbidden')); sys.path.insert(0,sys.argv[1]); sys.argv=[sys.argv[1]+'/preflight.py','--without-media-tools']; runpy.run_path(sys.argv[0],run_name='__main__')"
    result = subprocess.run([sys.executable, "-c", code, str(backend)],
                            env=env, cwd=tmp_path, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
    assert '"status": "ready"' in result.stdout
    assert (tmp_path / "data" / "users").is_dir()


def test_test_instance_identity_requires_temporary_marker(monkeypatch, tmp_path):
    monkeypatch.setenv("PEACEPLAYER_TEST_INSTANCE_ID", "fixture-id")
    config = RuntimeSettings.from_env({"PEACEPLAYER_DATA_DIR": str(tmp_path)})
    with pytest.raises(RuntimeError, match="matching marker"):
        _ = config.test_instance_id
    (tmp_path / ".peaceplayer-test-instance").write_text("fixture-id")
    assert config.test_instance_id == "fixture-id"
    ordinary = RuntimeSettings.from_env({"PEACEPLAYER_DATA_DIR": "/var/peaceplayer-production-data"})
    with pytest.raises(RuntimeError, match="temporary data"):
        _ = ordinary.test_instance_id


def test_startup_prepares_only_isolated_storage(monkeypatch, tmp_path):
    import asyncio
    import server
    from types import SimpleNamespace
    tool = tmp_path / "fake-media-tool"
    tool.write_text("#!/bin/sh\nexit 0\n")
    tool.chmod(0o700)
    config = RuntimeSettings.from_env({"PEACEPLAYER_DATA_DIR": str(tmp_path / "data"),
                                       "PEACEPLAYER_LIBRARY_DIR": str(tmp_path / "library"),
                                       "FFMPEG_BIN": str(tool), "DENO_BIN": str(tool)})
    monkeypatch.setattr(server, "settings", config)
    monkeypatch.setattr(server, "get_extractor", lambda: SimpleNamespace(output_dir=config.library_dir))
    asyncio.run(server.startup_event())
    assert config.users_dir.is_dir() and config.sync_dir.is_dir()
    assert config.audio_cache_dir.is_dir() and config.hls_dir.is_dir()
