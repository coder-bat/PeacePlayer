"""
Apple Sign-In authentication for PeacePlayer.

Verifies the `identityToken` (a JWT) that iOS produces when the
user taps "Sign in with Apple". The token is signed by Apple
with a per-app key. We fetch Apple's JWKS, verify the signature,
and mint our own short-lived session JWT for the client.

Why we verify the token (instead of trusting it):
- The iOS app posts the identityToken over the network. Anyone
  could craft a fake one. Without verification, the attacker
  could sign in as any Apple ID. Apple's JWKS proves the token
  was issued by Apple.

Why we mint our own session JWT (instead of passing Apple's):
- Apple's token is good for ~10 minutes — too short for an
  always-on music app. We re-issue one for 30 days.
- We can revoke our own session JWTs without invalidating the
  Apple ID.

Storage:
- Apple ID (`sub` claim) maps to a `user_id` (UUID v4) that we
  generate on first sign-in and persist in `data/users.json`.
- The session JWT carries the `user_id` (not the Apple ID) so
  the rest of the backend can refer to a stable user identity
  without re-verifying the Apple signature on every request.

2026-06-28
"""

import os
import json
import time
import uuid
import logging
from pathlib import Path
from typing import Optional, Tuple

import httpx
import jwt
from jwt import PyJWKClient

logger = logging.getLogger(__name__)

# Configuration. In production these should be set via env vars.
APPLE_TEAM_ID = os.environ.get("APPLE_TEAM_ID", "PEACEPLAYER_DEV_TEAM")
APPLE_BUNDLE_ID = os.environ.get("APPLE_BUNDLE_ID", "com.ytaudioplayer.app")
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_ISSUER = "https://appleid.apple.com"

# Our own secret for signing session JWTs.
#
# S17 (CV-3): the previous code silently fell back to a
# hardcoded "dev-secret-do-not-use-in-prod-32-chars-min"
# string. That meant an operator who forgot to set
# PEACEPLAYER_JWT_SECRET would ship the service with a
# publicly-known secret — anyone could forge a session JWT
# for any user_id. Now we fail fast on startup if the env
# var is missing, and we refuse to boot with a weak secret.
#
# Generate a real secret with:
#   python3 -c "import secrets; print(secrets.token_urlsafe(48))"
# and put it in backend/.env (gitignored) or export it
# before launching the service.
#
# The .env example (backend/.env.example) shows the variable
# name without a value, so it's safe to commit.
SESSION_JWT_SECRET = os.environ.get("PEACEPLAYER_JWT_SECRET")
if not SESSION_JWT_SECRET or SESSION_JWT_SECRET.strip() == "":
    raise RuntimeError(
        "PEACEPLAYER_JWT_SECRET is not set. Refusing to boot. "
        "Generate one with: python3 -c 'import secrets; "
        "print(secrets.token_urlsafe(48))' and put it in "
        "backend/.env (see backend/.env.example)."
    )
if len(SESSION_JWT_SECRET) < 32:
    raise RuntimeError(
        "PEACEPLAYER_JWT_SECRET must be at least 32 characters "
        "of high-entropy randomness. Got "
        f"{len(SESSION_JWT_SECRET)} characters."
    )

SESSION_JWT_ALG = "HS256"
SESSION_JWT_TTL_SECONDS = 30 * 24 * 60 * 60  # 30 days

# Per-process JWKS client. PyJWKClient caches keys with a TTL,
# so this is cheap to share across requests.
_jwks_client: Optional[PyJWKClient] = None


def _get_jwks_client() -> PyJWKClient:
    global _jwks_client
    if _jwks_client is None:
        # Cache keys for 1 hour — Apple rotates them rarely.
        _jwks_client = PyJWKClient(APPLE_JWKS_URL, cache_keys=True, lifespan=3600)
    return _jwks_client


# --- User storage (file-backed; swap for a real DB in prod) ---

USERS_DIR = Path(__file__).parent / "data" / "users"
USERS_DIR.mkdir(parents=True, exist_ok=True)


def _user_path(user_id: str) -> Path:
    return USERS_DIR / f"{user_id}.json"


def load_user(user_id: str) -> Optional[dict]:
    p = _user_path(user_id)
    if not p.exists():
        return None
    try:
        with open(p, "r") as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"Failed to read user {user_id}: {e}")
        return None


def save_user(user: dict) -> None:
    p = _user_path(user["user_id"])
    try:
        with open(p, "w") as f:
            json.dump(user, f, indent=2)
    except Exception as e:
        logger.error(f"Failed to write user {user['user_id']}: {e}")
        raise


def find_user_by_apple_sub(apple_sub: str) -> Optional[dict]:
    """Scan the users dir for a record matching the Apple subject.
    For the home server, a tiny user base means this is cheap.
    Swap for a real indexed DB in production."""
    if not USERS_DIR.exists():
        return None
    for path in USERS_DIR.glob("*.json"):
        try:
            with open(path, "r") as f:
                user = json.load(f)
            if user.get("apple_sub") == apple_sub:
                return user
        except Exception:
            continue
    return None


# --- Sync storage ---

SYNC_DIR = Path(__file__).parent / "data" / "sync"
SYNC_DIR.mkdir(parents=True, exist_ok=True)


def sync_path(user_id: str) -> Path:
    return SYNC_DIR / f"{user_id}.json"


def load_sync_blob(user_id: str) -> Optional[dict]:
    p = sync_path(user_id)
    if not p.exists():
        return None
    try:
        with open(p, "r") as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"Failed to read sync blob for {user_id}: {e}")
        return None


def save_sync_blob(user_id: str, blob: dict) -> None:
    try:
        with open(sync_path(user_id), "w") as f:
            json.dump(blob, f, indent=2)
    except Exception as e:
        logger.error(f"Failed to write sync blob for {user_id}: {e}")
        raise


# --- Apple identity-token verification ---

def verify_apple_identity_token(identity_token: str) -> dict:
    """Verify the iOS identity token against Apple's JWKS.

    Returns the decoded JWT claims on success. Raises jwt.PyJWTError
    on any failure (bad signature, expired, wrong audience, etc.).
    """
    client = _get_jwks_client()
    signing_key = client.get_signing_key_from_jwt(identity_token)

    claims = jwt.decode(
        identity_token,
        signing_key.key,
        algorithms=["RS256"],
        audience=APPLE_BUNDLE_ID,
        issuer=APPLE_ISSUER,
    )
    return claims


# --- Session JWT ---

def mint_session_jwt(user_id: str, apple_sub: str) -> str:
    """Issue a short-lived (30d) session JWT for the client to use
    on subsequent requests. The client posts this in the
    `Authorization: Bearer <token>` header."""
    now = int(time.time())
    payload = {
        "sub": user_id,           # our user_id (UUID)
        "apple_sub": apple_sub,   # the underlying Apple ID (for audit)
        "iat": now,
        "exp": now + SESSION_JWT_TTL_SECONDS,
        "iss": "peaceplayer",
    }
    return jwt.encode(payload, SESSION_JWT_SECRET, algorithm=SESSION_JWT_ALG)


def verify_session_jwt(token: str) -> Optional[dict]:
    """Verify a session JWT. Returns the decoded claims or None."""
    try:
        return jwt.decode(
            token,
            SESSION_JWT_SECRET,
            algorithms=[SESSION_JWT_ALG],
            issuer="peaceplayer",
        )
    except jwt.PyJWTError as e:
        logger.debug(f"Session JWT rejected: {e}")
        return None


def current_user_from_request(authorization: Optional[str]) -> Optional[dict]:
    """Extract the user record from a request's Authorization header.

    Returns None if the header is missing, malformed, or the token is
    invalid/expired. The caller should 401 in that case.
    """
    if not authorization or not authorization.startswith("Bearer "):
        return None
    token = authorization[len("Bearer "):].strip()
    claims = verify_session_jwt(token)
    if not claims:
        return None
    user = load_user(claims["sub"])
    return user


# --- User provisioning on first sign-in ---

def get_or_create_user(apple_sub: str, claims: dict) -> Tuple[dict, bool]:
    """Find the existing user with this Apple subject, or create one.

    Returns (user, is_new).
    """
    user = find_user_by_apple_sub(apple_sub)
    if user is not None:
        return user, False

    user_id = str(uuid.uuid4())
    user = {
        "user_id": user_id,
        "apple_sub": apple_sub,
        "email": claims.get("email"),  # may be None if user opted out
        "email_verified": claims.get("email_verified", False),
        "is_private_email": claims.get("is_private_email", False),
        "created_at": int(time.time()),
        "last_seen_at": int(time.time()),
    }
    save_user(user)
    logger.info(f"Created new user {user_id} for Apple sub {apple_sub[:8]}…")
    return user, True


def touch_last_seen(user_id: str) -> None:
    user = load_user(user_id)
    if not user:
        return
    user["last_seen_at"] = int(time.time())
    save_user(user)
