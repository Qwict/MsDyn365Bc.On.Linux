#!/usr/bin/env bash
# sql-image.sh — resolve / save / load the SQL Server image so CI can keep
# it in the Actions cache instead of pulling it from a registry every run.
#
# Run from a directory containing docker-compose.yml.
#
# Why cache THIS and not the BC artifacts: the SQL image is one image that
# changes a few times a year, so a digest-keyed entry stays valid for
# months. BC artifacts move revision several times a day and are ~3 GB per
# version against a 10 GB repo cache — caching those thrashes and never
# pays back. See CLAUDE.md; don't "improve" this by extending it to
# artifacts.
#
# The registry is the variable part of the fetch phase: the same SQL image
# has been measured at 105s, 45s and 104s on the same 2-vCPU runner class,
# with the compression format changing nothing. `docker load` from a local
# tar removes the registry from the critical path entirely.
#
# Usage:
#   sql-image.sh ref                 print the resolved image reference
#   sql-image.sh digest              print a cache-key-safe image digest
#   sql-image.sh load <tar>          docker load <tar> if it exists (else no-op)
#   sql-image.sh save <tar>          docker save the image to <tar>
#   sql-image.sh present             exit 0 if the image is in the local store

set -uo pipefail

# Mirror docker-compose.yml's default so the two can't drift apart
# silently. Keep in sync with the `sql` service's `image:` line.
DEFAULT_SQL_IMAGE="ghcr.io/stefanmaron/msdyn365bc.on.linux/mssql:2022-zstd"
SQL_IMAGE="${BC_SQL_IMAGE:-$DEFAULT_SQL_IMAGE}"

cmd="${1:-}"
case "$cmd" in
    ref)
        echo "$SQL_IMAGE"
        ;;

    digest)
        # Exact invalidation: a re-mirrored image produces a new key and
        # the cache entry is rebuilt. Falls back to a sanitized version of
        # the reference when the registry can't be reached, so a network
        # blip degrades to "cache by tag" rather than failing the job.
        d=$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$SQL_IMAGE" 2>/dev/null)
        if [ -n "$d" ]; then
            echo "${d#sha256:}"
        else
            echo "$SQL_IMAGE" | tr -c 'a-zA-Z0-9._-' '-'
        fi
        ;;

    present)
        docker image inspect "$SQL_IMAGE" >/dev/null 2>&1
        ;;

    load)
        tar="${2:?usage: sql-image.sh load <tar>}"
        if [ ! -f "$tar" ]; then
            echo "[sql-image] no cached tar at $tar — will pull instead"
            exit 1
        fi
        start=$(date +%s)
        if ! docker load -i "$tar" >/dev/null; then
            echo "[sql-image] WARN: docker load failed — falling back to a pull"
            exit 1
        fi
        # A tar that loads but doesn't produce the tag we expect is worse
        # than useless: compose would pull anyway and we'd have paid the
        # restore for nothing. Treat it as a miss.
        if ! docker image inspect "$SQL_IMAGE" >/dev/null 2>&1; then
            echo "[sql-image] WARN: $tar didn't contain $SQL_IMAGE — falling back to a pull"
            exit 1
        fi
        echo "[sql-image] loaded $SQL_IMAGE from cache in $(( $(date +%s) - start ))s"
        ;;

    save)
        tar="${2:?usage: sql-image.sh save <tar>}"
        mkdir -p "$(dirname "$tar")"
        start=$(date +%s)
        docker save "$SQL_IMAGE" -o "$tar" || {
            echo "[sql-image] WARN: docker save failed; cache will stay empty"
            rm -f "$tar"
            exit 0   # never fail the build over a cache write
        }
        echo "[sql-image] saved $SQL_IMAGE ($(du -h "$tar" | cut -f1)) in $(( $(date +%s) - start ))s"
        ;;

    *)
        echo "usage: $0 {ref|digest|present|load <tar>|save <tar>}" >&2
        exit 2
        ;;
esac
