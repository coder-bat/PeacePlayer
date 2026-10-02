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
DEADLINE_SECONDS = 3600


def main():
    import os
    import requests
    from ytmusicapi.auth.oauth import OAuthCredentials, RefreshingToken

    # Own OAuth client. ytmusicapi's built-in shared client authenticates fine
    # at Google's token endpoint but every actual YouTube Music request comes
    # back HTTP 400, so a personal client is required for real library access.
    # Read from the environment rather than argv so the secret does not land in
    # a process listing or shell history.
    client_id = os.environ.get("YT_OAUTH_CLIENT_ID") or None
    client_secret = os.environ.get("YT_OAUTH_CLIENT_SECRET") or None
    if bool(client_id) != bool(client_secret):
        print("Set BOTH YT_OAUTH_CLIENT_ID and YT_OAUTH_CLIENT_SECRET, or neither.",
              flush=True)
        return 2
    if client_id:
        print("using a personal OAuth client", flush=True)
        credentials = OAuthCredentials(client_id, client_secret,
                                       session=requests.Session())
    else:
        print("WARNING: no personal client supplied; falling back to ytmusicapi's "
              "shared client, which is expected to be rejected at the API", flush=True)
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
            # Google returns fields ytmusicapi's RefreshingToken does not accept
            # (e.g. refresh_token_expires_in). Passing the response through
            # **raw loses the token entirely, because the device code is
            # single-use -- you cannot go back and fetch it again. Filter to the
            # constructor's accepted arguments instead of assuming the payload
            # matches the signature.
            import inspect
            accepted = set(inspect.signature(RefreshingToken.__init__).parameters)
            fields = {k: v for k, v in raw.items() if k in accepted and k != "self"}
            missing = {"scope", "token_type", "access_token", "refresh_token"} - set(fields)
            if missing:
                raise ValueError(f"token response missing {sorted(missing)}")
            token = RefreshingToken(credentials=credentials, **fields)
            OUT.parent.mkdir(parents=True, exist_ok=True)
            payload = token.as_dict()
            # Preserve anything extra Google sent that is not part of the
            # token model, so nothing the server might need is discarded.
            for key, value in raw.items():
                payload.setdefault(key, value)
            OUT.write_text(json.dumps(payload, indent=1))
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
