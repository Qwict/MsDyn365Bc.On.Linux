#!/usr/bin/env bash
# compose-pull.sh — `docker compose pull` with a retry loop that can tell
# a transient failure from a permanent one.
#
# Run from a directory containing docker-compose.yml.
#
# Why this exists as a shared script rather than an inline loop:
#
#   mcr.microsoft.com intermittently WAF-blocks GitHub runner IPs, so the
#   pull genuinely needs retries. The inline version every workflow
#   carried slept 15s between five blind attempts — which is right for a
#   WAF block and completely wrong for "that tag doesn't exist". A
#   mistyped or not-yet-published image name burned 60s of sleep in every
#   matrix job before failing (or, worse, succeeding late and hiding the
#   mistake). That happened for real: a matrix run raced the workflow
#   that publishes the SQL mirror, and a 14s fetch phase showed up as
#   74s with nothing in the step output naming the cause.
#
# Permanent failures — unknown manifest, unauthorized, repository not
# found — abort immediately with the registry's own message, because no
# amount of waiting fixes them.
#
# Usage:
#   compose-pull.sh [service...]    pull all services, or only those named
#
# Naming services matters when one of them is already in the local image
# store — e.g. the SQL image restored from the Actions cache by
# sql-image.sh. `docker compose pull` would re-fetch it from the registry
# regardless, throwing away the cache hit.
#
# Env:
#   COMPOSE_PULL_ATTEMPTS   attempts before giving up (default 5)
#   COMPOSE_PULL_DELAY      seconds between attempts  (default 15)

set -uo pipefail

ATTEMPTS="${COMPOSE_PULL_ATTEMPTS:-5}"
DELAY="${COMPOSE_PULL_DELAY:-15}"
# Guarded expansion: `"${SERVICES[@]}"` on an empty array trips `set -u`
# on bash < 4.4, and this script is short enough not to gamble on that.
SERVICES=("$@")
if [ "${#SERVICES[@]}" -eq 0 ]; then SERVICES=(); fi

# Registry errors that will never resolve by waiting. Matched
# case-insensitively against the combined stdout+stderr of the attempt.
PERMANENT='manifest unknown|manifest for .* not found|not found: manifest|repository does not exist|name unknown|unauthorized|authentication required|denied: |access to the resource is denied|invalid reference format|no such host'

for attempt in $(seq 1 "$ATTEMPTS"); do
    out=$(docker compose pull --quiet "${SERVICES[@]}" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        [ "$attempt" -gt 1 ] && echo "[compose-pull] succeeded on attempt $attempt/$ATTEMPTS"
        exit 0
    fi

    echo "$out"

    if echo "$out" | grep -qiE "$PERMANENT"; then
        echo "[compose-pull] ERROR: permanent registry failure — not retrying."
        echo "[compose-pull] The image name or tag is wrong, not yet published,"
        echo "[compose-pull] or this runner can't authenticate to the registry."
        echo "[compose-pull] Images this compose file resolves to:"
        docker compose config --images 2>/dev/null | sed 's/^/[compose-pull]   /'
        exit 1
    fi

    if [ "$attempt" -lt "$ATTEMPTS" ]; then
        echo "[compose-pull] transient failure (attempt $attempt/$ATTEMPTS); retrying in ${DELAY}s..."
        sleep "$DELAY"
    fi
done

echo "[compose-pull] ERROR: docker compose pull failed after $ATTEMPTS attempts"
exit 1
