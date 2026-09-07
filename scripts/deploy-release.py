#!/usr/bin/env python3
"""Stage an exact commit and switch a preconfigured launchd service with rollback.

Requires an explicit external release root with private/service.env, explicit persistent data paths,
and a launchd agent using scripts/run-release.sh through a stable installed copy.
Does not install a service, rewrite a developer checkout, or change credentials.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.request import urlopen
from urllib.parse import urlsplit


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def switch_link(link: Path, target: Path):
    if link.exists() and not link.is_symlink():
        raise RuntimeError(f"Refusing to replace a real directory: {link.name}")
    temporary = link.with_name(link.name + ".next")
    if temporary.is_symlink():
        temporary.unlink()
    temporary.symlink_to(target, target_is_directory=True)
    temporary.replace(link)


def wait_ready(url, revision, attempts=20):
    for _ in range(attempts):
        try:
            with urlopen(url, timeout=2) as response:
                payload = json.load(response)
            if payload.get("status") == "ready" and payload.get("releaseCommit") == revision:
                return
        except (OSError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError("Release readiness failed; the previous release will be restored.")


def activate(release_root, candidate, restart, probe):
    current = release_root / "current"
    previous = current.resolve() if current.is_symlink() else None
    if previous is None:
        raise RuntimeError("Bootstrap a guarded current release before automated rollout; rollback must be available.")
    switch_link(current, candidate)
    try:
        restart()
        probe(candidate.name)
    except BaseException:
        switch_link(current, previous)
        restart()
        probe(previous.name)
        raise
    switch_link(release_root / "previous", previous)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("commit", help="Full commit SHA that passed required checks")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        raise SystemExit("A full tested commit SHA is required.")
    configured = os.environ.get("PEACEPLAYER_RELEASE_ROOT")
    label = os.environ.get("PEACEPLAYER_SERVICE_LABEL")
    health = os.environ.get("PEACEPLAYER_HEALTH_URL")
    if not configured or not label or not health:
        raise SystemExit("Configure PEACEPLAYER_RELEASE_ROOT, PEACEPLAYER_SERVICE_LABEL and PEACEPLAYER_HEALTH_URL (/ready).")
    endpoint = urlsplit(health)
    if endpoint.scheme != "http" or endpoint.hostname not in {"localhost", "127.0.0.1", "::1"} or endpoint.path != "/ready" or endpoint.username:
        raise SystemExit("Readiness must use the local service HTTP /ready endpoint.")
    root = Path(configured).expanduser().resolve()
    repo = Path(__file__).resolve().parents[1]
    if root.is_relative_to(repo) or repo.is_relative_to(root):
        raise SystemExit("Release storage must be separate from the source/developer checkout.")
    private = root / "private/service.env"
    if not private.is_file() or private.stat().st_mode & 0o077:
        raise SystemExit("Provide private/service.env with mode 0600 before deploying.")
    if not (root / "current").is_symlink():
        raise SystemExit("Initial guarded release and launchd service must be bootstrapped first.")
    # The local lock also protects manual runs, alongside workflow concurrency.
    with (root / ".deployment.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        if actual != args.commit:
            raise SystemExit("Checkout differs from tested commit; refusing deployment.")
        candidate = root / "releases" / args.commit
        if candidate.exists():
            raise SystemExit("This immutable release already exists; choose a new commit or investigate the previous attempt.")
        candidate.parent.mkdir(parents=True, exist_ok=True)
        run("git", "worktree", "add", "--detach", str(candidate), args.commit, cwd=repo)
        python = candidate / "backend/.venv/bin/python"
        run("python3.11", "-m", "venv", str(candidate / "backend/.venv"))
        run(str(python), "-m", "pip", "install", "-r", str(candidate / "backend/requirements.txt"))
        run(str(python), "-m", "pip", "check")
        environment = dict(os.environ, PEACEPLAYER_ENV_FILE=str(private),
                           PEACEPLAYER_REQUIRE_EXTERNAL_DATA="1",
                           PEACEPLAYER_RELEASE_COMMIT=args.commit)
        run(str(python), str(candidate / "backend/preflight.py"), env=environment, cwd=candidate / "backend")
        service = f"gui/{os.getuid()}/{label}"
        activate(root, candidate, lambda: run("launchctl", "kickstart", "-k", service),
                 lambda revision: wait_ready(health, revision))
        print("Deployed validated commit " + args.commit)


if __name__ == "__main__":
    main()
