#!/usr/bin/env python3
"""Run the YouTube Music OAuth device flow without needing a terminal prompt.

ytmusicapi's `setup_oauth` finishes with `input("... press Enter ...")` -- it
assumes a human sits at the terminal. Running it unattended would hang there
forever, so this performs the same flow but polls for the token instead, and
prints the verification URL so the only thing a human has to do is sign in with
Google in a browser.

Usage:
    python3 scripts/yt-oauth-device.py <output.json>

The output file is what PEACEPLAYER_OAUTH_FILE should point at.
"""
import json
import sys
import time
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "oauth.json")
POLL_SECONDS = 5
DEADLINE_SECONDS = 900


def main():
    from ytmusicapi.setup import setup_oauth  # noqa: F401  (import guard)
    from ytmusicapi.auth.oauth import OAuthCredentials, RefreshingToken
    import requests

    credentials = OAuthCredentials(session=requests.Session())
    code = credentials.get_code()
    url = f"{code['verification_url']}?user_code={code['user_code']}"

    print("=" * 68, flush=True)
    print("  Sign in to continue:", flush=True)
    print(f"  {url}", flush=True)
    print(f"  code: {code['user_code']}", flush=True)
    print("=" * 68, flush=True)
    print("Waiting for you to finish in the browser...", flush=True)

    started = time.time()
    announced = False
    while time.time() - started < DEADLINE_SECONDS:
        try:
            raw = credentials.token_from_code(code["device_code"])
        except Exception as exc:
            # Transport-level failure: back off and retry.
            print(f"  request error, retrying: {str(exc)[:70]}", flush=True)
            time.sleep(POLL_SECONDS)
            continue

        # While the browser step is unfinished Google answers with a JSON error
        # object, not a token. Constructing a token from that raises
        # "unexpected keyword argument 'error'" -- which reads like a bug in this
        # script but is really just the normal pending state.
        if "error" in raw:
            error = raw.get("error")
            if not announced:
                print(f"  waiting for browser sign-in... ({error})", flush=True)
                announced = True
            time.sleep(POLL_SECONDS)
            continue

        try:
            token = RefreshingToken(credentials=credentials, **raw)
            OUT.parent.mkdir(parents=True, exist_ok=True)
            OUT.write_text(json.dumps(token.as_dict(), indent=1))
            # 0600: this file is a live credential for the user's Google account.
            OUT.chmod(0o600)
            print(f"\nSuccess. Wrote {OUT}", flush=True)
            return 0
        except Exception as exc:
            print(f"  token rejected: {str(exc)[:100]}", flush=True)
            if "invalid_grant" in str(exc) or "expired" in str(exc):
                print("Device code expired or was denied. Re-run to get a new one.", flush=True)
                return 1
            time.sleep(POLL_SECONDS)

    print("Timed out waiting for the browser sign-in.", flush=True)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
