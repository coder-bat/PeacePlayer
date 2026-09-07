#!/bin/sh
# Install a stable copy outside release checkouts and point launchd at that copy.
set -eu
: "${PEACEPLAYER_RELEASE_ROOT:?Set the external release root in launchd}"
release_dir=$(cd "$PEACEPLAYER_RELEASE_ROOT/current" && pwd -P)
export PEACEPLAYER_ENV_FILE="$PEACEPLAYER_RELEASE_ROOT/private/service.env"
export PEACEPLAYER_REQUIRE_EXTERNAL_DATA=1
export PEACEPLAYER_RELEASE_COMMIT="${release_dir##*/}"
cd "$release_dir/backend"
exec "$release_dir/backend/.venv/bin/python" server.py
