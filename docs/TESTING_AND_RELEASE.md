# Backend testing and release operations

The supported backend runtime is Python 3.11 on macOS. Python packages are pinned in `backend/requirements.txt`; the direct dependency inputs are in `requirements.in`. FFmpeg and Deno are external prerequisites. Set `FFMPEG_BIN` and `DENO_BIN` to executable absolute paths in private service configuration when launchd does not expose their directory on PATH. Python yt-dlp subprocesses run through the same interpreter/package as imported extraction code.

## Clean local setup

From the repository root:

```sh
make setup-dev
make test
```

To keep a separate environment:

```sh
make setup-dev VENV=/tmp/peaceplayer-dev-env
make test VENV=/tmp/peaceplayer-dev-env
```

The default test suite creates temporary data/library roots and ephemeral signing keys before application imports. It disables prewarming and cleanup jobs and blocks socket connections. It does not start or use the ordinary backend. API contracts use HTTPX ASGITransport; startup/shutdown are exercised explicitly in lifecycle tests. The pinned Starlette TestClient is incompatible with HTTPX 0.28's removed `app=` argument, so use ASGITransport rather than introducing that wrapper.

Run `make check` only after configuring the private service environment. For offline startup/import validation with test configuration, use `preflight.py --without-media-tools`; this flag is for isolated tests, not production service startup. A missing/weak signing secret is an error and is never replaced automatically.

`requirements-dev.txt` locks test tooling and includes the runtime lock. To update dependencies, create a fresh Python 3.11 environment, edit the direct inputs, install them, regenerate the complete locks from that isolated environment, run `pip check` and the offline suite, and explicitly validate extraction against a disposable service. Never regenerate locks by freezing the normal development/runtime environment.

## Data and private configuration

`PEACEPLAYER_DATA_DIR` owns users, sync snapshots, cached audio, and HLS. `PEACEPLAYER_LIBRARY_DIR` owns downloaded library files. `PEACEPLAYER_OAUTH_FILE` is the optional YouTube account credential path; Apple sign-in remains required independently.

`PEACEPLAYER_ENV_FILE` selects the private dotenv configuration; `PEACEPLAYER_LOAD_DOTENV=0` disables all dotenv loading for tests. Environment variables override dotenv values. Startup validates media executables and creates configured storage directories.

## Explicit live integration checks

`backend/tests/live/` is excluded from default discovery. These tests contact external music services and some deliberately change cache files. They must never target the ordinary service or its data.

Provision a disposable backend with:

- A dedicated loopback port other than 8181.
- Temporary data/library roots, a generated signing key, and a disposable user/session.
- A random `PEACEPLAYER_TEST_INSTANCE_ID` in its environment.
- A `.peaceplayer-test-instance` file inside its temporary data root containing that same identifier.
- Prewarming/cleanup disabled so fixtures remain predictable.

Set the test process variables `PEACEPLAYER_RUN_LIVE_TESTS=1`, `PEACEPLAYER_TEST_BASE_URL`, `PEACEPLAYER_TEST_DATA_DIR`, `PEACEPLAYER_TEST_INSTANCE_ID`, and `PEACEPLAYER_TEST_SESSION_TOKEN` without printing the token. Then explicitly run:

```sh
cd backend
.venv/bin/python -m pytest tests/live
```

The harness refuses ordinary defaults and checks the server's `/health` instance identity before changing cache files. Failures are actual assertions even when the historical standalone report records counts. Keep these live checks separate from required offline CI because upstream availability is independent of application correctness.

## iOS tests

`python3 scripts/test-ios.py` discovers an available iOS runtime, creates a uniquely named iPhone simulator, runs the YTAudioPlayer scheme, and deletes only that simulator. Results go to `.test-artifacts`. It does not use an existing personal simulator. Xcode with an installed compatible iOS simulator runtime is required.

## Controlled macOS release

The workflow validates backend tests and iOS tests. A failed assertion, collection failure, or empty suite fails CI. Production rollout is manual through workflow dispatch, requires both validation jobs, and runs only on an explicitly configured `peaceplayer-deploy` macOS runner inside the private network. Configure the production environment and runner before enabling rollout. A source tag creates source release notes and makes no deployment or Docker-image claim.

The deployment script requires `PEACEPLAYER_RELEASE_ROOT`, `PEACEPLAYER_SERVICE_LABEL`, and a loopback `PEACEPLAYER_HEALTH_URL` ending in `/ready`. Release storage must be outside the developer/runner checkout. Example layout:

```text
<release-root>/
  private/service.env     # mode 0600; signing secret, tools, and explicit persistent paths
  releases/<commit>/      # immutable checkout and its own backend/.venv
  current                 # symlink to the active verified release
  previous                # symlink retained after a successful switch
```

The private file must explicitly select the existing persistent data and library paths. Do not copy an empty release data directory over existing user records. Keep the rotated key in private configuration. Install a stable copy of `scripts/run-release.sh` outside release checkouts and point launchd at that wrapper with `PEACEPLAYER_RELEASE_ROOT` configured. Initial migration of an existing service requires a separate verified bootstrap; the script refuses to deploy without a current release available for rollback.

The script verifies HEAD matches the full tested commit, creates a separate release/venv, installs the lock, checks dependencies and prerequisites, switches the symlink atomically, and restarts launchd. `/ready` must return `status=ready` and the candidate's `releaseCommit`. Failure restores the previous code/environment and restarts it without changing persistent user data or credentials. A local file lock and workflow concurrency serialize deployments. Previous releases are retained; no automated pruning removes rollback evidence.

An initial service whose `/ready` identity contract is unavailable must be migrated and verified before this automated switch is enabled. Rollback must retain the legacy upload guard and rotated secret; a pre-containment release is not an acceptable rollback target. The old `com.ytaudio.backend` service must remain disabled; verify the selected service is the sole listener on the backend port during bootstrap.
