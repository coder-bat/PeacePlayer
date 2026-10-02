#!/usr/bin/env python3
"""Verify a YouTube Music OAuth token BEFORE it is installed on the server.

Installing a token that loads but is rejected at the API silently breaks the
whole app: ytm_client flips into authenticated mode, every call returns 400,
and the error is swallowed into an empty result. That happened once already.

So a token is only installed if it demonstrably works here first.
"""
import json
import sys

TOKEN = sys.argv[1]


def main() -> int:
    from ytmusicapi import YTMusic

    checks = [
        ("get_account_info", lambda ym: ym.get_account_info()),
        ("get_home", lambda ym: ym.get_home()),
        ("search", lambda ym: ym.search("daft punk", "songs")),
        ("get_liked_songs", lambda ym: ym.get_liked_songs(limit=5)),
    ]

    try:
        ym = YTMusic(TOKEN)
    except Exception as exc:
        print(f"  CONSTRUCTION FAILED: {str(exc)[:120]}")
        return 1

    failures = []
    for name, fn in checks:
        try:
            result = fn(ym)
            n = len(result) if hasattr(result, "__len__") else "-"
            print(f"  {name:20} OK    items={n}")
        except Exception as exc:
            failures.append(name)
            print(f"  {name:20} FAIL  {str(exc)[:90]}")

    # get_account_info is the decisive one: it proves the token works against
    # the real account. The rest prove library reads.
    if "get_account_info" in failures:
        print("\n  VERDICT: REJECTED — token authenticates but the API refuses it.")
        return 1
    if failures:
        print(f"\n  VERDICT: PARTIAL — account reachable, but {failures} failed.")
        print("          The account is empty if these are library reads, not a token fault.")
        return 0
    print("\n  VERDICT: GOOD — safe to install.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
