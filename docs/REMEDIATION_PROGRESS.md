# Repair implementation evidence — 7 September 2026

Status: containment implemented and tested; runtime cutover/rotation pending independent review. Full plan remains in progress.

## Baseline and preservation

Branch `codex/repair-full-plan` retains the six pre-existing modified iOS files: app/widget Info.plist, Xcode project, project.yml, HomeView, and LibraryView. Starting diff and copies are privately preserved outside the repository. Neither untracked runtime nor old log is part of the changes.

Protected backup of the single user record and single sync snapshot completed. Copies have mode 0600 beneath a private mode-0700 directory. Both were restored to an isolated directory, parsed, and compared byte-for-byte by SHA-256. Original application data was not changed.

Private evidence root: `/Users/coderbat/.codex/private-remediation/iy-music-20260907-190709`. No credentials or library contents are included in this report.

## Phase 1 code and verification

- Legacy `/sync/upload` authenticates then returns HTTP 426 `legacy_sync_upgrade_required`, before snapshot mutation. Reads remain available.
- HLS integration test no longer embeds a signing secret, real account ID, or cached token path. It requires an explicitly supplied test-session token. Phase 2 is adding the disposable-service safety gate.
- Log-record redaction preserves Uvicorn access formatter argument shape and scrubs query credentials (including encoded query keys/values), Bearer/Basic headers, JWTs, and exception text. JSON formatting also redacts exception output.
- `PEACEPLAYER_DATA_DIR` isolates users/sync storage; `PEACEPLAYER_LOAD_DOTENV=0` prevents tests loading private settings. Route tests use ASGITransport without running service lifespan/prewarm.
- `test_containment.py`: **5 passed**. Tests cover Apple sign-in plus empty/populated legacy uploads preserving exact snapshot bytes; unauthenticated rejection; retained downloads; old-key rejection/new-key acceptance including actual header/query-token routes; missing/weak-secret fail-closed startup; access and exception-log redaction.
- Command: private pytest 8.4.2 overlay + backend/venv311 Python, `-m pytest tests/test_containment.py -q`. No live runtime packages were installed or upgraded. Initial attempts established venv311 lacked pytest and global 3.11 lacked slowapi; the private overlay resolved tooling without altering the service.
- Four FastAPI `on_event` deprecation warnings remain for the planned lifecycle refactor.
- Redacted exact-secret scan found **zero current tracked-tree matches**, **three affected historical commits**; see CREDENTIAL_SCAN_REDACTED.json. Git history has not been rewritten.

## Pending gates

Independent containment review; verified private release copy; activate legacy guard before forcing reauthentication; credential rotation and old-session rejection against deployed service; normal Apple sign-in requires the device/user flow. Historical cleanup requires explicit shared-history authorization. Remaining phases and device acceptance remain open.
