#!/usr/bin/env bash
#
# Deploy the backend to a Linux host (Docker) at one pinned, already-tested commit.
#
# Safety properties this script is built around:
#   * It never stops, restarts, or reconfigures the machine it runs on. Your
#     existing backend keeps serving until you deliberately cut over, so a
#     failure here is a no-op rather than an outage.
#   * Data is copied, never shared. The Mac and the host run different sync
#     formats; a shared mount would let the old writer corrupt the new store.
#   * The deploy is only reported as successful when /ready on the host returns
#     the exact commit that was requested.
#   * service.env is transferred with scp, never echoed, so the JWT secret does
#     not reach a shell history or a process argument list.
#
# Usage:
#   scripts/deploy-homelab.sh <host> <user> <full-commit-sha>
#
set -euo pipefail

HOST="${1:?usage: deploy-homelab.sh <host> <user> <full-commit-sha>}"
USER="${2:?usage: deploy-homelab.sh <host> <user> <full-commit-sha>}"
SHA="${3:?usage: deploy-homelab.sh <host> <user> <full-commit-sha>}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REMOTE_ROOT="/opt/peaceplayer"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "${USER}@${HOST}")
SCP=(scp -o BatchMode=yes -o ConnectTimeout=10)

LOCAL_DATA="${PEACEPLAYER_LOCAL_DATA:-${REPO}/backend/data}"
LOCAL_LIBRARY="${PEACEPLAYER_LOCAL_LIBRARY:-${HOME}/Music/YTAudio}"
LOCAL_ENV="${PEACEPLAYER_LOCAL_ENV:-${HOME}/.local/share/peaceplayer/private/service.env}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\n\033[31mFAIL: %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "commit must be a full 40-character SHA"
[[ -d "$LOCAL_DATA" ]] || die "data dir not found: $LOCAL_DATA (override with PEACEPLAYER_LOCAL_DATA)"
[[ -f "$LOCAL_ENV" ]] || die "service.env not found: $LOCAL_ENV (override with PEACEPLAYER_LOCAL_ENV)"

# Never deploy something that is not pushed; a host-side clone of an unpushed
# commit either fails or, worse, silently checks out something else.
git -C "$REPO" cat-file -e "${SHA}^{commit}" 2>/dev/null \
  || die "commit $SHA is not in this repository"
BRANCH="${PEACEPLAYER_DEPLOY_BRANCH:-$(git -C "$REPO" rev-parse --abbrev-ref HEAD)}"
git -C "$REPO" fetch --quiet origin "$BRANCH" 2>/dev/null || true
git -C "$REPO" merge-base --is-ancestor "$SHA" "origin/${BRANCH}" 2>/dev/null \
  || say "WARNING: $SHA is not on origin/${BRANCH}; the host clone may fail"

say "Preflight on ${USER}@${HOST}"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
command -v docker >/dev/null || { echo "docker is not installed"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose plugin missing"; exit 1; }
avail_kb=$(df --output=avail / | tail -1)
need_kb=$(( 2200 * 1024 ))
[ "$avail_kb" -ge "$need_kb" ] || { echo "insufficient disk: need ~2.2G, have $((avail_kb/1024))G"; exit 1; }
if ss -lnt 2>/dev/null | grep -q ':8181'; then echo "port 8181 is already in use"; exit 1; fi
# rsync is required on the *host* as well: the sender invokes the receiver's
# rsync binary over ssh, and a minimal Debian image has none. Installing it here
# keeps repeat deploys delta-transferred instead of re-sending 1.6G each time.
if ! command -v rsync >/dev/null; then
  echo "  installing rsync on the host ..."
  sudo -n apt-get update -qq
  sudo -n apt-get install -y -qq rsync >/dev/null
fi
echo "  docker $(docker --version | cut -d, -f1)"
echo "  rsync  $(rsync --version | head -1 | awk '{print $NF}')"
echo "  free   $((avail_kb/1024))G"
echo "  port   8181 free"
REMOTE

say "Creating ${REMOTE_ROOT} and fetching the pinned commit"
"${SSH[@]}" bash -s -- "$REMOTE_ROOT" "$SHA" <<'REMOTE'
set -euo pipefail
root="$1"; sha="$2"
sudo mkdir -p "$root/private" "$root/data" "$root/library"
sudo chown -R "$(id -un)":"$(id -gn)" "$root"
chmod 700 "$root/private"
if [ ! -d "$root/.src/.git" ]; then
  git clone --filter=blob:none https://github.com/coder-bat/PeacePlayer.git "$root/.src"
fi
git -C "$root/.src" fetch --all --tags --quiet
git -C "$root/.src" checkout --quiet --detach "$sha"
echo "  checked out $(git -C "$root/.src" rev-parse HEAD)"
# The build context must be the repo checkout, because the Dockerfile copies
# backend/*. A symlink from the deployment root would make the context
# $root, which has no backend/ at all, and the build fails on the COPY.
# PEACEPLAYER_HOST_ROOT is how compose finds data/ and private/ from in there.
REMOTE

say "Transferring secrets (scp; never echoed)"
"${SCP[@]}" "${LOCAL_ENV}" "${USER}@${HOST}:${REMOTE_ROOT}/private/service.env"
"${SSH[@]}" "chmod 600 '${REMOTE_ROOT}/private/service.env'"

say "Copying data (this is the slow part)"
if [ -d "$LOCAL_LIBRARY" ]; then
  "${SSH[@]}" "mkdir -p '${REMOTE_ROOT}/library'"
  rsync -az --stats -e "ssh -o BatchMode=yes" \
    "${LOCAL_DATA}/" "${USER}@${HOST}:${REMOTE_ROOT}/data/"
  rsync -az --stats -e "ssh -o BatchMode=yes" \
    "${LOCAL_LIBRARY}/" "${USER}@${HOST}:${REMOTE_ROOT}/library/"
else
  say "NOTE: library dir ${LOCAL_LIBRARY} absent; copying data only"
  rsync -az --stats -e "ssh -o BatchMode=yes" \
    "${LOCAL_DATA}/" "${USER}@${HOST}:${REMOTE_ROOT}/data/"
fi

say "Building image and starting the service"
"${SSH[@]}" bash -s -- "$REMOTE_ROOT" "$SHA" <<'REMOTE'
set -euo pipefail
root="$1"; sha="$2"
# Build from the checkout, not the deployment root: the context must contain
# backend/ for the Dockerfile's COPY. Data and secrets are found through
# PEACEPLAYER_HOST_ROOT, which the compose file interpolates into the mounts.
cd "$root/.src"
export PEACEPLAYER_RELEASE_COMMIT="$sha"
export PEACEPLAYER_HOST_ROOT="$root"
docker compose -f docker-compose.homelab.yml build --pull
docker compose -f docker-compose.homelab.yml up -d
REMOTE

say "Waiting for /ready to report ${SHA}"
for attempt in $(seq 1 30); do
  payload="$(curl -fsS -m 5 "http://${HOST}:8181/ready" 2>/dev/null || true)"
  if printf '%s' "$payload" | grep -q "\"releaseCommit\":\"${SHA}\""; then
    printf '\n\033[32mDeployed %s\033[0m\n' "$SHA"
    curl -fsS -m 5 "http://${HOST}:8181/auth-status"; echo
    printf '\nCutover is NOT done. Verify from the app, then:\n'
    printf '  * Settings -> Configure backend server -> http://%s:8181\n' "$HOST"
    printf '  * only then change ios/Sources/BackendConfiguration.swift:43\n'
    exit 0
  fi
  printf '  attempt %02d/30 %s\n' "$attempt" "${payload:-<no response>}"
  sleep 4
done

"${SSH[@]}" "cd '${REMOTE_ROOT}' && PEACEPLAYER_RELEASE_COMMIT='${SHA}' docker compose logs --tail 60" || true
die "service did not report commit ${SHA}; nothing was changed on the source machine"
