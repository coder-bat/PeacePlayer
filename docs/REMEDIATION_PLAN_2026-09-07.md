# PeacePlayer repair plan — 7 September 2026

Status: planned; no application fixes, credential rotation, or deployment performed.

## Outcome and scope

Repair every finding from the project analysis: exposed signing secret, destructive sync, unreproducible backend setup, ineffective deployment tests, inconsistent backend-host changes, blocking backend requests, concentrated application complexity, and stale documentation. Include the related sync and test-harness defects verified during planning, because the original fixes cannot work safely without addressing them.

Preserve the personal, self-hosted product, its current features, and existing user data. Keep the current SwiftUI/AVPlayer/Core Data and FastAPI stack. No visual redesign or new music sources are part of this plan. The older polish plans are historical context, not an additional backlog imported into this repair effort.

Repository: `/Users/coderbat/iYMusic/YTAudioSystem`. The outer `/Users/coderbat/iYMusic` folder is not a Git repository.

## Phase 0 — Documentation discovery and baseline

Discovery completed for this plan. Before implementation, re-read the relevant source references and check for intervening changes; line numbers below reflect the planning snapshot.

### Verified baseline

- Debug simulator build of the app and widget passed with Xcode 26.6. Warnings remain; this was a build, not an iOS test run.
- Four isolated backend download-retry tests passed. Backend Python files parsed successfully.
- Live playback, live sync, real-device behavior, and the full test suite have not been validated in this analysis.
- Six tracked files already contain user changes: app/widget Info.plist files, the Xcode project, `ios/project.yml`, HomeView, and LibraryView. Preserve them and record their starting diff before editing. There are also an untracked runtime directory and old server log; neither belongs in a repair commit.
- The committed test secret matches local `.env`. The installed service configuration has no explicit JWT override and launches this backend directory. Effective running-process credentials were not inspected. Treat the configured secret as exposed without printing it or using it to forge requests.

### Existing APIs and patterns to reuse

| Concern | Existing API/pattern and source |
|---|---|
| Authentication | `mint_session_jwt`, `verify_session_jwt`, `current_user_from_request`: [apple_auth.py](/Users/coderbat/iYMusic/YTAudioSystem/backend/apple_auth.py:202). Preserve issuer/signature verification and the fail-fast secret requirement. |
| Sync entry points | `handleSignIn(isNewUser:)`, `handleSessionRestored()`, `handleSignOut()`: [SyncService.swift](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/SyncService.swift:62). These exist; the proposed versioned protocol below does not. |
| Current playlist store | `PlaylistManager.playlists`, `likedTracks`, `loadPlaylists()`, `savePlaylists()`: [PlaylistManager.swift](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/PlaylistManager.swift:15). The persistence methods are private; add a narrow import/export seam rather than assuming a public upsert exists. |
| Backend address | Computed `APIService.baseURL` and `baseURLOverrideDefaultsKey`: [APIService.swift](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/APIService.swift:35). Reuse its Settings override semantics. |
| Playback boundaries | `AVPlayerController.init(playerState:)`, `setupObservers()`, `removeTimeObserver()`: [AVPlayerController.swift](/Users/coderbat/iYMusic/YTAudioSystem/ios/YTAudioPlayer/Models/AVPlayerController.swift:119). `QueueController.next(useCrossfade:userSkipped:)`: [QueueController.swift](/Users/coderbat/iYMusic/YTAudioSystem/ios/YTAudioPlayer/Models/QueueController.swift:135). |
| Focused observable state | `PlaybackClock.tick`, `reset`, and direct instance tests: [PlaybackClockTests.swift](/Users/coderbat/iYMusic/YTAudioSystem/ios/YTAudioPlayerTests/PlaybackClockTests.swift:18). Copy the instance-per-test setup; assert publisher emissions when testing deduplication. |
| Backend test doubles | Mock extraction, downloads, conversion, and backoff as in [test_extractor_retry.py](/Users/coderbat/iYMusic/YTAudioSystem/backend/tests/test_extractor_retry.py:80). Replace its fixed temporary directory with a per-test directory before parallel execution. |
| Build configuration | App/widget/test targets and iOS 17 minimum: [project.yml](/Users/coderbat/iYMusic/YTAudioSystem/ios/project.yml:1). Preserve exclusions for unfinished source files. |

### Finding coverage

| ID | Finding | Repair phase |
|---|---|---|
| F1 | Exposed signing secret and unsafe forced-sign-in interaction | 1 |
| F2 | Upload-before-restore data loss; broken decoder, wrong playlist store, missing history links | 1 containment, 3 full repair |
| F3 | Missing dependencies, runtime/version drift, machine-specific paths | 2 |
| F4 | Swallowed test failures, live/destructive tests mixed into CI | 2 |
| F5 | Auth/sync use stale backend addresses | 4 |
| F6 | Synchronous upstream work blocks asynchronous routes and health checks | 5 |
| F7 | Oversized backend/player/screens and tightly coupled shared state | 6 |
| F8 | Documentation disagrees with the current product | 7 |
| V1 | Device, sync, playback, and complete-test verification gaps | 8 |

## Phase 1 — Protect backups, then contain the credential exposure

Dependencies: Phase 0. This is the first operational release; do not wait for the broad refactor.

### Implement

1. Record the starting source diff. Back up server user records and sync snapshots to a protected location outside the repository. Verify that copies can be read and restored in an isolated directory. Do not copy credentials into reports or fixtures.
2. Add a server-side guard to reject legacy/unversioned sync uploads before touching existing snapshots. During containment, temporarily reject all such uploads with an explicit service error; keep reads available. Returning an error is essential because the old client would otherwise claim success.
3. Add a regression test proving that sign-in followed by an old empty upload leaves the existing snapshot byte-for-byte intact. Use generated test keys and isolated user/sync directories.
4. Remove the literal signing secret and real-user assumptions from the E2E test. Generate ephemeral secrets for isolated tests; explicitly supplied test-service credentials are required for opt-in integration tests. Never fall back to a development secret.
5. Prepare the guarded backend release and a rotation runbook. Deploy the upload guard before or together with secret rotation; verify it is active before forcing any reauthentication. Generate and install a new secret through the selected private configuration source, restart the service, and verify normal Apple sign-in. Old tokens must be rejected. Do not retain the exposed key as a fallback.
6. Scan tracked content and history with redacted output. Remove exposed material from the current tree. Prepare any shared-history rewrite separately with a list of affected refs and collaborator impact; execute that irreversible rewrite only when explicitly authorized. Rotation is the containment measure and must not wait for history cleanup.
7. Audit token-bearing playback URLs in application/backend logs. Redact tokens and Authorization values, including access logging for query-token endpoints. Keep the existing playback authentication mechanism during this repair.

### References, checks, and guards

Read [test_e2e_hls_latency.py](/Users/coderbat/iYMusic/YTAudioSystem/backend/tests/test_e2e_hls_latency.py:31), [sync_upload](/Users/coderbat/iYMusic/YTAudioSystem/backend/server.py:684), [save_sync_blob](/Users/coderbat/iYMusic/YTAudioSystem/backend/apple_auth.py:170), and the authentication APIs in Phase 0. Locate secrets by path/line or redacted scanner output, never by displaying their values.

Acceptance: protected snapshots survive legacy uploads; old-key tokens fail in isolated rotation tests; new sessions work after the controlled cutover; logs/reports contain no tokens; current tracked files contain no usable signing secret. Runtime rotation and any history cleanup need separate recorded completion evidence.

Rollback: restore application code only to a version retaining the upload guard. Keep the new secret. Do not restore the compromised credential or overwrite newer user snapshots.

## Phase 2 — Make setup reproducible and tests enforceable

Dependencies: Phase 0; may be developed while Phase 1 is prepared, but does not delay containment.

### Implement

1. Inventory direct imports and the installed working packages without exporting unrelated environment values. Add missing `slowapi` and `httpx`. Select Python 3.11 as the initial supported baseline, matching the configured service runtime. Derive a tested, reproducible dependency lock from an isolated environment; do not blindly freeze the entire developer machine.
2. Reconcile the declared `yt-dlp` version with the executable actually used by each extraction path. Record FFmpeg and Deno prerequisites as well as Python packages. Pin a tested version set; choose updates only after the smoke/contract checks pass.
3. Centralize runtime/data-directory configuration. Resolve Python tools from the selected runtime and allow validated environment overrides for external binaries. Remove developer-home defaults from production paths, cache paths, tests, Makefile, and deploy scripts. Missing prerequisites must produce actionable startup errors.
4. Introduce a backend test configuration with temporary data roots, ephemeral users/keys, fake upstream responses, and no automatic service startup or prewarming. Separate offline unit/contract tests from explicitly enabled live integration tests.
5. Repair the test harness before enabling broad discovery: the HLS test deletes cache files and assumes localhost is the test server; the radio test calls real YouTube and a hardcoded executable. Require a dedicated disposable service/root for live tests and refuse destructive cache tests against the ordinary service. Replace custom failure counters with real test assertions: the HLS script's final exit status is only checked by its standalone entry point, so pytest can otherwise miss recorded failures.
6. Remove `pytest || echo "No tests yet"`. A failing assertion, collection error, or unexpectedly empty required suite must fail CI. Make pytest/dev dependencies explicit. Add an iOS simulator test job on a compatible macOS/Xcode runner, using a disposable simulator because existing tests touch shared stores.
7. Gate deployment on required checks and deploy the tested commit into a separate release checkout/environment. Serialize deployments and verify the runner can reach the private Mac service through the intended network before enabling rollout. Preserve private config and data outside release checkouts. Replace the current destructive reset of the developer checkout; keep a previous release for rollback. Do not substitute branch tip for the tested commit or deploy main when master triggered validation.
8. Align release messages with real artifacts and deployments. Do not claim Docker images or successful deployment merely because a tag exists. Select the macOS service as the supported deployment route; mark obsolete Docker instructions as legacy unless they receive equivalent verification.

### References, checks, and guards

Read [requirements.txt](/Users/coderbat/iYMusic/YTAudioSystem/backend/requirements.txt:1), [Makefile](/Users/coderbat/iYMusic/YTAudioSystem/Makefile:1), [deploy.yml](/Users/coderbat/iYMusic/YTAudioSystem/.github/workflows/deploy.yml:53), [release.yml](/Users/coderbat/iYMusic/YTAudioSystem/.github/workflows/release.yml:1), and [radio test](/Users/coderbat/iYMusic/YTAudioSystem/backend/tests/test_ytdlp_radio_extractor.py:45). Reuse the mocked retry-test pattern from Phase 0.

Acceptance: a fresh checkout in a differently named directory installs, passes dependency consistency checks, imports the server with isolated configuration, and starts without undeclared packages. Required tests run without YouTube or production data. An intentionally failing temporary test makes the validation job fail and prevents deploy; remove that fixture after verifying the gate. App/widget builds and the isolated iOS suite pass. A rollback rehearsal switches code/environment without restoring stale user data.

Guard: no dependency upgrades in the live runtime while constructing the lock; no production cache deletion; no broad test runs against the user's normal simulator before isolation is established.

## Phase 3 — Repair backup and restore end to end

Dependencies: Phase 1 upload protection and Phase 2 isolated test infrastructure. Land backend support before enabling the new client writer.

### Implement

1. Define shared JSON fixtures for upload, download, empty account, existing snapshot, and error responses. Fix the mismatch where iOS `download()` decodes `UploadRequest` requiring `clientVersion`, but the server response omits it. Use distinct, correctly typed response/request models with an explicit schema version.
2. Introduce a versioned sync contract with server-owned revision numbers and conditional writes. Proposed fields `schemaVersion`, `revision`, and `baseRevision` are new APIs: document them before implementation. Reject a stale base revision and preserve the snapshot; the client must fetch and merge again with a bounded retry.
3. Replace upload-first sign-in with fetch → validate → merge → persist locally → upload against the fetched revision. Apply this to both new and existing accounts. A network error, cancellation, decoding failure, or local save failure must never turn into an empty upload. First install without a prior local baseline is not evidence that remote data was deleted.
4. Keep the existing PlaylistManager/UserDefaults store as the current source of truth. Add an explicit import/export adapter preserving IDs, track order, names, and supported metadata, and publish restored data to the UI. Inventory legacy CDPlaylist records and merge recoverable entries by ID with backups; do not silently delete either store or attempt a broad persistence migration in the same change.
5. Include enough track metadata in the new schema to recreate linked records offline. Upsert CDTrack records before restored history, preserve distinct listening events, and deduplicate by a stable event identity. Ensure restored history survives an export/import round trip. Support legacy snapshots with missing metadata through a documented placeholder/hydration path.
6. Persist a last-synced baseline scoped to backend origin and account. Use a three-way merge to distinguish additions, edits, and explicit deletions; do not use a permanent union that resurrects deleted favorites/playlists. On incompatible concurrent playlist edits, preserve the competing content as a recoverable conflict copy instead of silently discarding it.
7. Stage imports and propagate all persistence errors. Preserve a recoverable pre-merge snapshot across UserDefaults/Core Data writes so a partial failure can be retried safely. Serialize sync operations; check account/session generation after awaits so sign-out or host changes prevent stale results from committing. Preserve and tag retained local data with its account owner: switching Apple accounts must never automatically upload the previous account's library. Keep unowned legacy data recoverable and require an explicit import choice before publishing it under a different account.
8. Store server snapshots with atomic replacement, bounded backup retention, and a per-user revision check under the same write lock. Distinguish a missing snapshot from an unreadable/corrupt snapshot; corruption must return a recovery error and must never authorize creating an empty replacement. Document the initial single-process service constraint; multiple workers require a shared transactional store/lock, not merely a process-local lock.
9. Keep legacy uploads blocked. Old snapshot reads remain migratable. Expose honest sync status/retry to the user, and publish the new client only after backend compatibility is in place.

### References, checks, and guards

Read [SyncService flows](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/SyncService.swift:89), [decoder and collection](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/SyncService.swift:194), [merge](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/SyncService.swift:251), [PlaylistManager persistence](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/PlaylistManager.swift:45), and [backend models](/Users/coderbat/iYMusic/YTAudioSystem/backend/server.py:535). Copy the track/history creation pattern around `CDTrack.fetchOrCreate` and `CDPlayHistory.create` in [DataManager.swift](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/DataManager.swift:164), after reading their actual signatures. Reuse the existing auth entry points; implement the new storage adapter explicitly rather than calling nonexistent APIs. Do not reuse the store-recovery `backupAndReload()` operation for ordinary sync backup: it moves/reloads the store and is not a nondestructive snapshot API.

Acceptance matrix: existing account on a fresh install; truly new account; local-only changes; populated local and remote libraries; empty remote; corrupt remote snapshot; unavailable server; malformed response; interrupted local/server write; stale revision; repeated restore; concurrent edits/deletions; sign-out during download; account switch with retained local data; legacy snapshot; missing track metadata. Every case checks actual UI-store contents and the next exported snapshot. No successful status after a failed save. No personal library is used for these tests.

Rollback: keep versioned server data and legacy-write rejection. If a new client is faulty, disable new uploads and retain read-only recovery; do not roll back to upload-first behavior.

## Phase 4 — Make backend changes consistent across the app

Dependencies: Phase 2; integrate with Phase 3's origin/account scoping.

### Implement

1. Create one backend-configuration provider based on the existing computed `APIService.baseURL`. Inject/read it at request creation in APIService, AuthService, SyncService, health checks, downloads, and URL caches. Audit other captured addresses rather than fixing only two declarations.
2. A host change must atomically invalidate pending work and cached remote URLs. Bind session tokens and sync baselines to the normalized origin; never forward the old origin's token to a new server. Preserve local files and library data, and require authentication for the new origin.
3. Capture the origin/session generation for each operation and discard stale completions. Do not resolve a relative response URL using a different host that became active midway through the request.
4. Make server-address configuration reachable before sign-in as well as in Settings, since the main UI is currently gated by authentication. Validate supported URL schemes and show connection/authentication errors separately.

### References, checks, and guards

Read [APIService.baseURL](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/APIService.swift:35), [AuthService captured URL](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/AuthService.swift:29), [SyncService captured URL](/Users/coderbat/iYMusic/YTAudioSystem/ios/Sources/SyncService.swift:44), and [ContentView sign-in gate](/Users/coderbat/iYMusic/YTAudioSystem/ios/YTAudioPlayer/Views/ContentView.swift:36).

Acceptance: switch between two local stub origins while logged out, logged in, syncing, and resolving a stream. All subsequent requests use the selected server; the second server receives no first-server credential; stale callbacks cannot update playback or storage; local files remain intact. Test normalized trailing slashes/ports and invalid URLs. Keep the existing private-network HTTP support; this phase does not introduce an unrelated transport migration.

## Phase 5 — Keep the backend responsive under slow upstream calls

Dependencies: Phase 2. Preserve the external route contracts tested there.

### Implement

1. Inventory blocking operations in async routes, startup/prewarm jobs, Apple token verification, and sync persistence. Start with search, stream resolution, thumbnail fetches, and `/health`.
2. Introduce a bounded execution gateway for synchronous ytmusicapi/yt-dlp work. Keep serialized access to shared clients inside the worker's real work lifetime, including background-thread callers. Use asynchronous HTTP for ordinary fetches where already supported.
3. Specify timeouts, bounded queues, cleanup, and cancellation semantics. Cancelling an await does not necessarily stop a thread: do not release shared-client protection while underlying work still runs. Kill and reap subprocesses on timeout/cancellation where applicable.
4. Make `/health` a cheap local service probe that preserves fields the current iOS client consumes. Add an explicitly documented readiness check for deployment and a separate bounded upstream diagnostic. A YouTube outage should not make the app think its own backend is unreachable or cause a healthy process to restart repeatedly.
5. Add redacted operation timings and distinguish uncached extraction from cached playback. Record measurements; remove unsupported instant-start claims rather than inventing a latency result.

### References, checks, and guards

Read [search](/Users/coderbat/iYMusic/YTAudioSystem/backend/server.py:741), [stream resolution](/Users/coderbat/iYMusic/YTAudioSystem/backend/server.py:803), [thumbnail proxy](/Users/coderbat/iYMusic/YTAudioSystem/backend/server.py:1727), and [health_check](/Users/coderbat/iYMusic/YTAudioSystem/backend/server.py:2632). Reuse existing `httpx.AsyncClient` usage and asynchronous subprocess patterns only after checking their cancellation behavior; merely wrapping a blocking call in an async function does not fix this issue.

Acceptance: hold a fake upstream call open for three seconds; concurrently require local health to complete within a generous one-second test budget on CI. Check bounded concurrency, serialized shared-client access, timeout cleanup, and continued service after upstream failure. Verify no leaked workers/subprocesses and no response-contract regressions. Rehearse a slow dependency without real YouTube access.

## Phase 6 — Reduce complexity in bounded, behavior-preserving changes

Dependencies: Phases 2–5 regression coverage. Split into independently reviewable commits; do not combine structural moves with new playback behavior.

### Implement

1. Backend: extract configuration, authentication/sync routes, discovery routes, and playback/cache jobs from `server.py`. Keep one explicit owner for clients, locks, caches, and background tasks. Preserve route names, authentication, response shapes, and startup/shutdown semantics. Add a test app factory so importing a module does not start operational work.
2. Player: retain the public PlayerState facade while separating track resolution/transitions from radio/podcast/audiobook session handling. Reuse the existing AVPlayerController, QueueController, GaplessController, AudioSessionController, and PlaybackClock boundaries. Inject resolver/storage/clock seams for meaningful tests; do not add more implicit global dependencies.
3. Define playback ownership and stale-request handling explicitly. Preserve the intentional crossfade overlap while ensuring obsolete players/observers are released. Test fast A→B selections, duplicate play requests, end-of-track events, seek, shuffle/repeat, crossfade, gapless, and pause versus system interruption.
4. Extract named presentational sections and embedded view models from FullPlayer, HomeView, and LibraryView. Keep existing state ownership, navigation, gestures, and accessibility identifiers stable. Add focused rendering/interaction checks only where the extraction can affect them.
5. Document thread/actor ownership at each boundary and resolve warnings in touched code that threaten correctness. A wholesale Swift concurrency migration and unrelated warning cleanup are separate work, not prerequisites for this bounded repair.

### References, checks, and guards

Copy the controller ownership and forwarding patterns cited in Phase 0, checking implementation rather than trusting their historical comments. Read [PlayerState play entry](/Users/coderbat/iYMusic/YTAudioSystem/ios/YTAudioPlayer/Models/PlayerState.swift:1104), [FullPlayer sections](/Users/coderbat/iYMusic/YTAudioSystem/ios/YTAudioPlayer/Views/Player/FullPlayer.swift:316), and the existing Home/Library changes before moving code.

Acceptance: server composition contains wiring rather than domain operations; PlayerState delegates the two extracted responsibilities with testable interfaces; the three screens have separate sections/view-model files without changed UX; existing and new behavioral tests pass. Measure before/after file sizes and dependencies as supporting evidence, not arbitrary line-count targets. Repeated transitions must not grow observer/player counts without bound. Keep unfinished unified-source files excluded unless separately repaired.

## Phase 7 — Publish one accurate set of project documentation

Dependencies: update alongside each phase; final pass after Phase 6.

### Implement

1. Make the repository README the canonical entry point. Update architecture, setup, API reference, and deployment instructions to reflect the tested runtime, iOS 17 minimum, mandatory Apple sign-in, distinct optional YouTube authentication, actual persistence stores, safe sync protocol, and streaming paths.
2. Explain which content is local, which data is backed up on the self-hosted Mac, and what a backend outage prevents. Do not call the Mac-backed snapshot service an unspecified cloud backup.
3. Document host changes, sync conflict/retry behavior, credential rotation, local test isolation, dependency updates, service rollout, and rollback. Provide placeholders rather than developer-specific addresses or secrets.
4. Mark older plans/recovery summaries as historical where users could confuse them with current instructions. Make the outer README point to the canonical repository docs without importing the outer folder into Git. Retire unverified Docker/release claims.

### References, checks, and guards

Read [README](/Users/coderbat/iYMusic/YTAudioSystem/README.md:20), [architecture](/Users/coderbat/iYMusic/YTAudioSystem/docs/ARCHITECTURE.md:57), [setup guide](/Users/coderbat/iYMusic/YTAudioSystem/docs/SETUP_GUIDE.md:1), and [outer README](/Users/coderbat/iYMusic/README.md:1). Historical documents may explain decisions but are not current API specifications.

Acceptance: follow setup from a clean directory using only documented prerequisites; check links/commands; compare API examples against contract fixtures; remove guest-mode, iOS 15, no-local-storage, obsolete endpoint, and unmeasured latency claims from current docs. History documents may retain dated statements when clearly labeled.

## Phase 8 — Verification and controlled release

Dependencies: all implementation phases. This is the completion gate, not a substitute for per-phase tests.

1. Run the isolated backend unit/contract suite, fresh-environment setup check, iOS test suite, and Debug/Release app/widget builds. Compare warnings to baseline and record any remaining limitations.
2. Verify every finding ID has a change reference and passing acceptance evidence. Check for exposed credentials, developer-home assumptions in active config, swallowed failures, stale captured hosts, unsafe legacy uploads, and blocking work left in async handlers. Inspect matches rather than treating a grep count as proof.
3. Rehearse the complete backend-and-client upgrade using copied/fixture data, including a populated account and older client. Demonstrate backup restoration, rejected unsafe writes, stale revisions, and rollback without restoring the compromised key.
4. Run opt-in live integration tests only against a dedicated test service, data root, and test account. Test the current `/stream` → `/fast` route and cached audio route; do not treat old HLS-only checks as coverage of current playback.
5. On a real iPhone, verify sign-in/restore, downloaded playback while the backend is unavailable, fresh and cached streams, rapid track changes, background/screen-lock playback, interruptions, AirPlay, queue changes, crossfade/gapless, radio, podcast/audiobook resume, widgets/Live Activities, and Smart Library protections. Check the affected screens with VoiceOver and Reduce Motion. Record measured cold/warm startup times separately.
6. Prepare the final release with exact commit/runtime versions, data compatibility, health/rollback evidence, and a short user-visible change note. Deploy only within the execution authorization; this planning request alone does not deploy anything.

Completion requires evidence, not just green compilation. If real-device access or external sign-in is unavailable, leave those checks explicitly pending; do not mark the whole repair complete.

## Execution order and review boundaries

Recommended sequence: **0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8**. Documentation changes accompany each phase. Phase 2 preparation can overlap Phase 1; phases 4 and 5 can be developed independently once shared test/config boundaries are stable.

Use separate reviewable changes for containment, environment/test infrastructure, backend sync protocol, iOS sync integration, host handling, backend responsiveness, each backend/player/UI extraction, and documentation. Each change records files touched, tests/results, behavior affected, migration/rollback considerations, and remaining checks. Preserve the initial user diff throughout.

The first milestone is protected data and invalidated exposed credentials. The second is working restore plus enforced, reproducible checks. The third is responsive playback infrastructure and completed structural cleanup. Dates should be estimated after the isolated full-suite baseline; the previous simulator build and four tests are insufficient evidence for a reliable delivery estimate.
