"""Portable, environment-driven backend paths and prerequisite validation.

Importing configuration may load the selected dotenv file, but creates no directories or jobs.
The service and tests must select their environment before importing the app.
"""
from dataclasses import dataclass
from pathlib import Path
import importlib.metadata
import os
import shutil
import sys
import tempfile

BACKEND_DIR = Path(__file__).resolve().parent


def load_environment() -> None:
    if os.environ.get("PEACEPLAYER_LOAD_DOTENV", "1") == "0":
        return
    from dotenv import load_dotenv
    env_file = Path(os.environ.get("PEACEPLAYER_ENV_FILE", BACKEND_DIR / ".env"))
    if env_file.is_file():
        load_dotenv(env_file, override=False)


def _path(env: dict, name: str, default: Path) -> Path:
    return Path(env.get(name, str(default))).expanduser().resolve()


def _binary(env: dict, name: str, executable: str) -> str:
    explicit = env.get(name)
    if explicit:
        return str(Path(explicit).expanduser().resolve())
    return shutil.which(executable, path=env.get("PATH")) or executable


@dataclass(frozen=True)
class RuntimeSettings:
    data_dir: Path
    library_dir: Path
    oauth_file: Path
    ffmpeg_bin: str
    deno_bin: str
    python_bin: str

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        return cls(
            data_dir=_path(env, "PEACEPLAYER_DATA_DIR", BACKEND_DIR / "data"),
            library_dir=_path(env, "PEACEPLAYER_LIBRARY_DIR", Path.home() / "Music" / "YTAudio"),
            oauth_file=_path(env, "PEACEPLAYER_OAUTH_FILE", BACKEND_DIR / "oauth.json"),
            ffmpeg_bin=_binary(env, "FFMPEG_BIN", "ffmpeg"),
            deno_bin=_binary(env, "DENO_BIN", "deno"),
            python_bin=sys.executable,
        )

    @property
    def audio_cache_dir(self):
        return self.data_dir / "audio_cache"

    @property
    def hls_dir(self):
        return self.data_dir / "hls"

    @property
    def users_dir(self):
        return self.data_dir / "users"

    @property
    def sync_dir(self):
        return self.data_dir / "sync"

    @property
    def ytdlp_command(self):
        # Library and subprocess extraction always use the same pinned package.
        return (self.python_bin, "-m", "yt_dlp")

    @property
    def test_instance_id(self):
        instance = os.environ.get("PEACEPLAYER_TEST_INSTANCE_ID")
        if not instance:
            return None
        temporary_root = Path(tempfile.gettempdir()).resolve()
        marker = self.data_dir / ".peaceplayer-test-instance"
        if (not self.data_dir.is_relative_to(temporary_root) or self.data_dir == temporary_root
                or not marker.is_file() or marker.read_text().strip() != instance):
            raise RuntimeError("Test instance ID requires a matching marker in a dedicated temporary data directory.")
        return instance

    def validate(self, *, media_tools=True):
        self.test_instance_id  # Validate disposable identity before any startup work.
        if sys.version_info[:2] != (3, 11):
            raise RuntimeError("PeacePlayer requires Python 3.11; recreate the environment with python3.11.")
        if os.environ.get("PEACEPLAYER_REQUIRE_EXTERNAL_DATA") == "1":
            for key, directory in (("PEACEPLAYER_DATA_DIR", self.data_dir),
                                   ("PEACEPLAYER_LIBRARY_DIR", self.library_dir)):
                if not os.environ.get(key) or directory.is_relative_to(BACKEND_DIR):
                    raise RuntimeError(f"Set {key} in private service configuration to persistent storage outside the release.")
        importlib.metadata.version("yt-dlp")
        if media_tools:
            for name, value in (("FFMPEG_BIN", self.ffmpeg_bin), ("DENO_BIN", self.deno_bin)):
                if not Path(value).is_file() or not os.access(value, os.X_OK):
                    raise RuntimeError(f"Missing executable for {name}; install the tool and set {name} to its absolute path.")

    def prepare_directories(self):
        for directory in (self.data_dir, self.library_dir, self.audio_cache_dir,
                          self.hls_dir, self.users_dir, self.sync_dir):
            directory.mkdir(parents=True, exist_ok=True)


load_environment()
settings = RuntimeSettings.from_env()
DATA_DIR = settings.data_dir
AUDIO_CACHE_DIR = settings.audio_cache_dir
HLS_DIR = settings.hls_dir
USERS_DIR = settings.users_dir
SYNC_DIR = settings.sync_dir
LIBRARY_DIR = settings.library_dir
YTDLP_COMMAND = settings.ytdlp_command
FFMPEG_BIN = settings.ffmpeg_bin
DENO_BIN = settings.deno_bin
