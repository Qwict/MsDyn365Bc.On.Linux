#!/bin/bash
# Download BC artifacts (platform + country) to a target directory.
# Supports both public and insider artifact URLs.
#
# Performance design:
#   - App and platform zips are downloaded IN PARALLEL to a fast temp dir
#     (host tmpfs / runner /tmp) rather than directly to the destination
#     volume.  This avoids writing the raw zip into the (slower) Docker
#     named volume and cuts the effective I/O to the volume by ~50%.
#   - Each zip is fetched with MULTIPLE PARALLEL BYTE-RANGE STREAMS
#     (BC_DL_STREAMS per file, default 8). Azure Front Door serves a
#     POP-cache MISS at only ~4-8 MB/s PER CONNECTION (origin fetch),
#     while the same POP serves cache hits at 200+ MB/s — that's the
#     source of the notorious 30s-vs-6min variance. AFD uses chunked
#     object caching, so N concurrent range requests pull origin chunks
#     in parallel and multiply cold-miss throughput by ~N. The direct
#     blob endpoint (bcartifacts.blob.core.windows.net) is no longer an
#     option: Microsoft put it behind a network security perimeter
#     (403), so AFD is the only door.
#   - Every range stream aborts and retries when it crawls below
#     1 MB/s for 30s (--speed-limit/--speed-time) — a reconnect usually
#     lands a healthier origin connection, and by then AFD has cached
#     the chunks already pulled.
#   - Timing is logged for each phase so you can see exactly where time
#     goes: version resolution, download, and extraction.
#
# Usage:
#   With full URL:  download-artifacts.sh <url> <dest>
#   With parts:     download-artifacts.sh <type> <version> <country> <dest>
set -e

_ms() { date +%s%3N; }

# Parallel range streams per file (two files download concurrently, so the
# total connection count is 2x this). 8 is a good default: ~8x cold-miss
# throughput without hammering AFD; override with BC_DL_STREAMS.
STREAMS="${BC_DL_STREAMS:-8}"

# Fetch one byte range to a part file, with slow-transfer abort + retries.
# A stream stuck below 1 MB/s for 30s is killed and reconnected — AFD
# origin connections occasionally degenerate, and a fresh connection
# (plus the chunks AFD cached meanwhile) is almost always faster.
_fetch_range() {
    local url="$1" out="$2" start="$3" end="$4"
    local want=$((end - start + 1)) attempt got
    for attempt in 1 2 3; do
        if curl -sf --http1.1 --retry 2 --retry-all-errors \
                --speed-limit 1000000 --speed-time 30 \
                -r "$start-$end" "$url" -o "$out"; then
            got=$(stat -c%s "$out" 2>/dev/null || echo 0)
            if [ "$got" -eq "$want" ]; then
                return 0
            fi
            echo "[artifacts] WARN: range $start-$end returned $got of $want bytes (attempt $attempt)" >&2
        else
            echo "[artifacts] WARN: range $start-$end failed or stalled <1MB/s (attempt $attempt)" >&2
        fi
        sleep 2
    done
    echo "[artifacts] ERROR: range $start-$end failed after 3 attempts" >&2
    return 1
}

# Download a URL using $STREAMS parallel byte-range streams, then stitch
# the parts together. Falls back to a plain single-stream curl when the
# server doesn't advertise range support or a usable Content-Length.
_ranged_download() {
    local url="$1" out="$2"
    local head size
    head=$(curl -sfI --http1.1 --retry 3 --retry-all-errors "$url" | tr -d '\r') || head=""
    size=$(echo "$head" | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)
    if ! echo "$head" | grep -qi '^accept-ranges: *bytes' || \
       ! echo "$size" | grep -qE '^[0-9]+$' || [ "$size" -lt $((16 * 1024 * 1024)) ]; then
        curl -sSL --retry 3 --retry-all-errors --http1.1 \
             --speed-limit 1000000 --speed-time 60 "$url" -o "$out"
        return
    fi

    local chunk=$(( (size + STREAMS - 1) / STREAMS ))
    local i start end pids=() rc=0
    for ((i = 0; i < STREAMS; i++)); do
        start=$((i * chunk))
        end=$((start + chunk - 1))
        if [ "$end" -ge "$size" ]; then end=$((size - 1)); fi
        if [ "$start" -gt "$end" ]; then break; fi
        _fetch_range "$url" "$out.part$i" "$start" "$end" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then rc=1; fi
    done
    if [ "$rc" -ne 0 ]; then return 1; fi

    # Explicit index loop — a glob would order part10 before part2.
    : > "$out"
    for ((i = 0; i < ${#pids[@]}; i++)); do
        cat "$out.part$i" >> "$out"
        rm -f "$out.part$i"
    done
    local total
    total=$(stat -c%s "$out")
    if [ "$total" -ne "$size" ]; then
        echo "[artifacts] ERROR: stitched $total bytes, expected $size ($url)" >&2
        return 1
    fi
}

# Parse arguments: either (url, dest) or (type, version, country, dest)
if [ $# -eq 2 ]; then
    APP_URL="$1"
    DEST="$2"
    # Derive platform URL: replace country segment with "platform"
    PLATFORM_URL=$(echo "$APP_URL" | sed 's|/[^/]*$|/platform|')
elif [ $# -eq 4 ]; then
    BC_TYPE="$1"; BC_VERSION="$2"; BC_COUNTRY="${3,,}"; DEST="$4"
    BASE_URL="https://bcartifacts-exdbf9fwegejdqak.b02.azurefd.net"

    # Resolve short version (e.g. "27.5") to full version (e.g. "27.5.46862.48612)
    # using the per-country JSON index file that Microsoft maintains for
    # navcontainerhelper:
    #
    #   https://bcartifacts.blob.core.windows.net/<type>/indexes/<country>.json
    #
    # This is the canonical approach used by BcContainerHelper's
    # QueryArtifactsFromIndex (HelperFunctions.ps1:1721) — it's a static
    # JSON object, NOT the list-blobs API. Avoids the AFD list-blobs cache
    # poisoning that plagued earlier versions of this script
    # (microsoft/navcontainerhelper#4119), which would intermittently return
    # stale 27.0/27.1/27.2 entries when asked for prefix=27.5.
    #
    # To skip the resolver entirely, pass a fully-qualified version like
    # "27.5.46862.48612" via BC_VERSION — the regex below sees three parts
    # and goes straight to the download.
    if ! echo "$BC_VERSION" | grep -qP '^\d+\.\d+\.\d+'; then
        echo "[artifacts] Resolving version $BC_VERSION via Microsoft's index file..."
        T_RESOLVE=$(_ms)
        REQUESTED_PREFIX="$BC_VERSION"
        INDEX_URL="$BASE_URL/${BC_TYPE}/indexes/${BC_COUNTRY}.json"
        RESOLVED=""
        # Three attempts in case of transient network errors. The index
        # file is a regular cached blob, so it doesn't suffer the
        # list-blobs API's stale-cache problem; one retry is usually
        # plenty.
        for attempt in 1 2 3; do
            RESOLVED=$(curl -sf --retry 2 --retry-delay 2 "$INDEX_URL" 2>/dev/null | \
                BC_PREFIX="$REQUESTED_PREFIX" python3 -c "
import json, os, sys
prefix = os.environ['BC_PREFIX'] + '.'
try:
    data = json.load(sys.stdin)
except Exception as e:
    sys.exit(1)
versions = [d['Version'] for d in data if d.get('Version', '').startswith(prefix)]
if not versions:
    sys.exit(0)
def vkey(v):
    return tuple(int(x) for x in v.split('.'))
versions.sort(key=vkey)
print(versions[-1])
" 2>/dev/null || true)
            if [ -n "$RESOLVED" ] && echo "$RESOLVED" | grep -q "^${REQUESTED_PREFIX}\."; then
                break
            fi
            RESOLVED=""
            echo "[artifacts] WARN: attempt $attempt — index file unreachable or no '$REQUESTED_PREFIX.x' versions found; retrying..."
            sleep 3
        done
        if [ -z "$RESOLVED" ]; then
            echo "[artifacts] ERROR: Could not resolve version $REQUESTED_PREFIX from $INDEX_URL"
            echo "[artifacts] Workaround: pin BC_VERSION to a fully-qualified version, e.g.:"
            echo "[artifacts]   BC_VERSION=27.5.46862.48612 docker compose up -d --wait"
            exit 1
        fi
        echo "[artifacts] Resolved: $REQUESTED_PREFIX → $RESOLVED ($(( $(_ms) - T_RESOLVE ))ms)"
        BC_VERSION="$RESOLVED"
    fi

    APP_URL="$BASE_URL/$BC_TYPE/$BC_VERSION/$BC_COUNTRY"
    PLATFORM_URL="$BASE_URL/$BC_TYPE/$BC_VERSION/platform"
else
    echo "Usage: $0 <artifact-url> <dest>"
    echo "   or: $0 <type> <version> <country> <dest>"
    exit 1
fi

echo "[artifacts] App URL:      $APP_URL"
echo "[artifacts] Platform URL: $PLATFORM_URL"

# Download zips to a temp dir (host /tmp is fast tmpfs/SSD, not a Docker volume).
# This avoids writing ~1-3 GB of zip data into the destination volume just to
# immediately delete them after extraction — halving the volume write load.
TMPDIR_DL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DL"' EXIT

mkdir -p "$DEST/app" "$DEST/platform"

# ── Parallel download ──────────────────────────────────────────────────────
echo "[artifacts] Downloading app + platform in parallel ($STREAMS range streams each)..."
T0=$(_ms)
_ranged_download "$APP_URL"      "$TMPDIR_DL/app.zip"      &
APP_PID=$!
_ranged_download "$PLATFORM_URL" "$TMPDIR_DL/platform.zip" &
PLATFORM_PID=$!

wait $APP_PID      || { echo "[artifacts] ERROR: app artifact download failed";      exit 1; }
wait $PLATFORM_PID || { echo "[artifacts] ERROR: platform artifact download failed"; exit 1; }

T_DOWNLOADED=$(_ms)
APP_BYTES=$(stat -c%s "$TMPDIR_DL/app.zip")
PLAT_BYTES=$(stat -c%s "$TMPDIR_DL/platform.zip")
TOTAL_MB=$(( (APP_BYTES + PLAT_BYTES) / 1024 / 1024 ))
DOWNLOAD_MS=$(( T_DOWNLOADED - T0 ))
# Avoid divide-by-zero if somehow instantaneous
SPEED_MBS=$(( DOWNLOAD_MS > 0 ? TOTAL_MB * 1000 / DOWNLOAD_MS : 0 ))
echo "[artifacts] Downloaded: app=$(du -h "$TMPDIR_DL/app.zip" | cut -f1) platform=$(du -h "$TMPDIR_DL/platform.zip" | cut -f1) in ${DOWNLOAD_MS}ms (~${SPEED_MBS} MB/s)"

# ── Extract ────────────────────────────────────────────────────────────────
echo "[artifacts] Extracting app..."
T_EXTRACT=$(_ms)
unzip -qo "$TMPDIR_DL/app.zip" -d "$DEST/app"

PLATFORM_VERSION=$(python3 -c "import json; print(json.load(open('$DEST/app/manifest.json'))['platform'])" 2>/dev/null)
echo "[artifacts] Platform version: $PLATFORM_VERSION"

echo "[artifacts] Extracting platform (ServiceTier, ModernDev, WebClient, applications, Test Assemblies)..."
# Selective extraction keeps only what the service tier needs (~50% of the zip)
# WebClient is needed for TestPage client DLLs (page testability in tests)
unzip -qo "$TMPDIR_DL/platform.zip" 'ServiceTier/*' 'ModernDev/*' 'WebClient/*' 'applications/*' 'Test Assemblies/*' -d "$DEST/platform" 2>/dev/null || \
    unzip -qo "$TMPDIR_DL/platform.zip" -d "$DEST/platform"

T_DONE=$(_ms)
EXTRACT_MS=$(( T_DONE - T_EXTRACT ))
TOTAL_MS=$(( T_DONE - T0 ))
echo "[artifacts] Extracted in ${EXTRACT_MS}ms | Total: ${TOTAL_MS}ms | Disk: $(du -sh "$DEST" | cut -f1)"

echo "[artifacts] Done. Artifacts at $DEST"
