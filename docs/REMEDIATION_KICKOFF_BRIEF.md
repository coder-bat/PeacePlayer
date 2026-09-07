# Research brief: PeacePlayer repair

The first release must protect saved server snapshots before exposed-key rotation forces sign-in. Existing iOS sync uploads first and overwrites a snapshot; its decoder and playlist source also disagree with backend data. Fix this with guarded legacy writes, a versioned conditional-write contract, and restore/merge before publishing.

Reuse existing Apple JWT verification and PlaylistManager storage. Preserve six user-modified iOS files. Backend synchronous upstream operations require bounded work ownership; cancelling an await does not terminate its worker. HTTPX 0.28 removed the deprecated `app` argument; use ASGITransport with AsyncClient for installed Starlette compatibility. Use pytest monkeypatch and temporary directories before import, with private dotenv disabled. Backend imports must not start live work.

Official references: https://docs.python.org/3.11/library/concurrent.futures.html ; https://github.com/encode/httpx/releases/tag/0.28.0 ; https://www.python-httpx.org/advanced/transports/ ; https://docs.pytest.org/en/stable/how-to/monkeypatch.html .

UI flow: fetch/validate/merge/persist/upload with honest pending/error status, account-and-origin scoped baselines, recoverable conflicts, and explicit import of retained foreign-account data. Keep current navigation and controls; no redesign.
