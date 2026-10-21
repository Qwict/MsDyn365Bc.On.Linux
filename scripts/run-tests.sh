#!/usr/bin/env bash
# run-tests.sh — Run AL tests on a BC Linux container
#
# Hybrid execution: OData for setup + WebSocket for execution + OData for results.
# The WebSocket path creates a proper client session (serviceConnection) required
# for TestPage support. OData handles suite population and result reading.
#
# Usage:
#   ./scripts/run-tests.sh [options]
#
# Options:
#   --app <path>               Test app file (auto-published + codeunit discovery)
#   --codeunit-range <range>   Codeunit IDs to test. Accepts:
#                                "70000"                            single id
#                                "70000..70010"                     AL range
#                                "50000..50100|130450..130459"      multiple ranges (pipe)
#                                "50000,50001,50002"                explicit ids
#                                "50000..50100,130450,200000..210000" mixed
#   --junit-output <path>      Write per-test results as JUnit XML to <path>.
#                                Compatible with GitHub Checks reporters
#                                (dorny/test-reporter, EnricoMi/publish-unit-test-result-action),
#                                Azure DevOps "Publish Test Results" task, and
#                                AL-Go's AnalyzeTests post-step. Default off.
#   --coverage-output <path>   Record code coverage while the suite runs and write it
#                              to <path> as CSV: object_type,object_id,line_no,hits —
#                              one row per executable line of the apps under test.
#                              Best effort: a coverage failure is reported, never
#                              fails the run. Needs Test Runner Extension 3.4 (legacy
#                              report: every loaded partner object, lines only).
#   --coverage-app <guid>      An app under test (repeatable). Default: the dependencies
#                              of the --app test app, minus Microsoft's apps and apps
#                              whose name contains "test" (test libraries). The resolved
#                              scope is printed. Scoped coverage needs Test Runner
#                              Extension 4.0; older ones record every loaded partner
#                              object instead (legacy mode).
#   --coverage-cobertura <path>  Also write the coverage as Cobertura XML (package per
#                              app, class per object, every Code line; methods need
#                              Test Runner Extension 4.0).
#   --coverage-lcov <path>     Also write the coverage as an LCOV tracefile (functions
#                              need Test Runner Extension 4.0).
#   --coverage-root <dir>      The directory the report's file paths are relative to
#                              (the repository root). Default: the git toplevel of
#                              --coverage-source when that is inside a git work tree,
#                              else --coverage-source itself.
#   --coverage-source <dir>    Directory with the apps' .al sources. Objects are mapped
#                              to their files so Cobertura/LCOV name repository-relative
#                              paths and file line numbers. Without it a class is named
#                              after its object ("Codeunit 50100").
#                              Any of the three outputs turns coverage recording on.
#   --company <name>           Company name (default: auto-detect)
#   --base-url <url>           BC base URL (default: http://localhost:7048/BC)
#   --dev-url <url>            BC Dev endpoint (default: http://localhost:7049/BC/dev)
#   --api-url <url>            BC API endpoint (default: derived from --base-url)
#   --auth <user:pass>         Authentication (default: BCRUNNER:Admin123!)
#   --timeout <minutes>        Overall timeout (default: 30)
#   --test-runner-app <path>   TestRunnerExtension .app (auto-detected)

set -uo pipefail

# CDPATH makes cd print the resolved directory, which corrupts $(cd ... && pwd)
unset CDPATH

# === Configuration & CLI Parsing ===
BASE_URL="http://localhost:7048/BC"
DEV_URL="http://localhost:7049/BC/dev"
API_URL=""
# Matches the container's login (BC_SERVER_USERNAME/BC_SERVER_PASSWORD in
# docker-compose.yml — see scripts/entrypoint.sh); override with --auth if
# the container was booted with a non-default login.
AUTH="${BC_SERVER_USERNAME:-BCRUNNER}:${BC_SERVER_PASSWORD:-Admin123!}"
COMPANY=""
CODEUNIT_RANGE=""
APP_FILE=""
TIMEOUT_MIN=30
DISABLED_TESTS_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_RUNNER_APP=""
JUNIT_OUTPUT=""
COVERAGE_OUTPUT=""
COVERAGE_COBERTURA=""
COVERAGE_LCOV=""
COVERAGE_SOURCE=""
COVERAGE_ROOT=""
COVERAGE_ALL_SESSIONS=0
COVERAGE_TMP=""
COVERAGE_APPS=()
RENEW_CLIENT_CONTEXT=0

show_help() {
    cat <<'HELPEOF'
Usage: run-tests.sh [options]

Options:
  --app <path>               Test app file (auto-published + codeunit discovery)
  --codeunit-range <range>   Codeunit IDs to test. Accepts:
                               "70000"                            single id
                               "70000..70010"                     AL range
                               "50000..50100|130450..130459"      multiple ranges (pipe)
                               "50000,50001,50002"                explicit ids
                               "50000..50100,130450,200000..210000" mixed
  --junit-output <path>      Write per-test results as JUnit XML to <path>
  --coverage-output <path>   Record code coverage while the suite runs and write it
                             to <path> as CSV: object_type,object_id,line_no,hits —
                             one row per executable line of the apps under test.
                             Best effort: a coverage failure is reported, never
                             fails the run. Needs Test Runner Extension 3.4 (its
                             legacy report: every loaded partner object, lines only).
  --coverage-app <guid>      An app under test (repeatable). Default: the dependencies
                             of the --app test app, minus Microsoft's apps and apps
                             whose name contains "test" (test libraries). The resolved
                             scope is printed. Scoped coverage needs Test Runner
                             Extension 4.0; older ones record every loaded partner
                             object instead (legacy mode).
  --coverage-cobertura <path>  Also write the coverage as Cobertura XML (methods need
                             Test Runner Extension 4.0)
  --coverage-lcov <path>     Also write the coverage as an LCOV tracefile (functions
                             need Test Runner Extension 4.0)
  --coverage-source <dir>    Directory with the apps' .al sources, so Cobertura and
                             LCOV name repository-relative paths and file line numbers
                             (default: classes are named after their object).
  --coverage-root <dir>      Directory the report's file paths are relative to, the
                             repository root. Default: the git toplevel of
                             --coverage-source if it is inside a git work tree, else
                             --coverage-source itself.
  --coverage-all-sessions    Record the hits of every session on the service tier, not
                             only the test session (default). Needs Test Runner
                             Extension 4.1; an older one records the test session only.
                             On a multitenant service tier this also records other
                             tenants' sessions (more overhead, foreign hits).
                             Any of the three outputs turns coverage recording on.
  --company <name>           Company name (default: auto-detect)
  --base-url <url>           BC OData base URL (default: http://localhost:7048/BC)
  --dev-url <url>            BC Dev endpoint (default: http://localhost:7049/BC/dev)
  --api-url <url>            BC API endpoint (default: derived from --base-url)
  --auth <user:pass>         Authentication (default: BCRUNNER:Admin123!)
  --timeout <minutes>        Overall timeout (default: 30)
  --test-runner-app <path>   TestRunnerExtension .app (auto-detected)
  --disabled-tests <dir>     Directory with DisabledTests JSON files
  --renew-client-context     Open a NEW client session before every test codeunit.
                             Off by default, matching BcContainerHelper's
                             RenewClientContextBetweenTests default: one session runs
                             the whole suite, so SingleInstance codeunit state carries
                             across test codeunits the way it does on a real tier.
                             Turn this on only to reproduce the pre-#65 behaviour.
  -h, --help                 Show this help

Examples:
  # Run tests from a compiled .app
  ./scripts/run-tests.sh --app MyTestApp.app --codeunit-range 50000..50100

  # Remote BC (e.g. from a devcontainer / Codespace)
  ./scripts/run-tests.sh --base-url http://172.17.0.1:7048/BC --app MyTestApp.app
HELPEOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help;;
        --app) APP_FILE="$2"; shift 2;;
        --codeunit-range) CODEUNIT_RANGE="$2"; shift 2;;
        --company) COMPANY="$2"; shift 2;;
        --base-url) BASE_URL="$2"; shift 2;;
        --dev-url) DEV_URL="$2"; shift 2;;
        --api-url) API_URL="$2"; shift 2;;
        --auth) AUTH="$2"; shift 2;;
        --timeout) TIMEOUT_MIN="$2"; shift 2;;
        --test-runner-app) TEST_RUNNER_APP="$2"; shift 2;;
        --disabled-tests) DISABLED_TESTS_DIR="$2"; shift 2;;
        --junit-output) JUNIT_OUTPUT="$2"; shift 2;;
        --coverage-output) COVERAGE_OUTPUT="$2"; shift 2;;
        --coverage-cobertura) COVERAGE_COBERTURA="$2"; shift 2;;
        --coverage-lcov) COVERAGE_LCOV="$2"; shift 2;;
        --coverage-source) COVERAGE_SOURCE="$2"; shift 2;;
        --coverage-root) COVERAGE_ROOT="$2"; shift 2;;
        --coverage-all-sessions) COVERAGE_ALL_SESSIONS=1; shift;;
        --coverage-app) COVERAGE_APPS+=("$2"); shift 2;;
        --renew-client-context) RENEW_CLIENT_CONTEXT=1; shift;;
        --host|--test-runner|--suite-name|--codeunit-timeout|--extension-id|--sql-password) shift 2;;
        *) echo "Unknown option: $1 (try --help)"; exit 1;;
    esac
done

echo "=== BC Test Runner ==="

# --- Helper ---
py3() { env -u PYTHONHOME -u PYTHONPATH python3 "$@"; }

# Derive scheme://host (no port, no path) and instance path from BASE_URL
# so fallback URLs on other ports use the same host instead of hardcoded localhost.
_URL_ORIGIN=$(echo "$BASE_URL" | sed -E 's|(https?://[^:/]+).*|\1|')
_BC_PATH=$(echo "$BASE_URL" | sed -E 's|https?://[^/]+(/.*)$|\1|')
[ -z "$_URL_ORIGIN" ] && _URL_ORIGIN="http://localhost"
[ -z "$_BC_PATH" ] && _BC_PATH="/BC"
_API_FALLBACK="${_URL_ORIGIN}:7052${_BC_PATH}"
[ -n "$API_URL" ] && _API_FALLBACK="$API_URL"

# --- Find TestRunnerExtension .app ---
if [ -z "$TEST_RUNNER_APP" ]; then
    TEST_RUNNER_APP="$REPO_DIR/extensions/TestRunnerExtension/TestRunnerExtension.app"
fi
if [ ! -f "$TEST_RUNNER_APP" ]; then
    echo "ERROR: TestRunnerExtension .app not found at $TEST_RUNNER_APP"
    exit 1
fi

# === Company Auto-Detection ===
# ODataV4/Company is tried FIRST, ahead of the API v2.0 endpoint:
#   - It's the URL the container healthcheck polls every 2s, so it's
#     already warm by the time any test runs.
#   - API v2.0 lives in the _Exclude_APIV2_ extension, which is NOT in
#     the keep set for a minimal selective-clear boot — asking for it
#     first means a 404 and a pointless fallback hop on exactly the
#     lean configurations we recommend.
#   - It exposes Evaluation_Company, which is what actually identifies
#     the CRONUS demo company. Taking value[0] blind picks whichever row
#     sorts first, and the demo database ships more than one company
#     ("My Company" is in there too).
# The API v2.0 endpoints stay as fallbacks for servers where the OData
# Company page isn't exposed.
COMPANIES_JSON=""
for url in "${BASE_URL}/ODataV4/Company" \
           "${BASE_URL}/api/v2.0/companies" \
           "${_API_FALLBACK}/api/v2.0/companies"; do
    COMPANIES_JSON=$(curl -sf --max-time 10 -u "$AUTH" "$url" 2>/dev/null || true)
    [ -n "$COMPANIES_JSON" ] && break
done
if [ -z "$COMPANIES_JSON" ]; then
    echo "ERROR: Cannot reach BC. Is it running?"
    exit 1
fi

# Resolve name AND id in one pass. When --company was given, its row is
# looked up by name so the id belongs to the requested company rather
# than to whichever one auto-detect would have picked. Otherwise prefer
# the evaluation (demo) company, falling back to the first row when the
# payload doesn't carry the flag. Keys are lowercased because the OData
# page and the API v2.0 entity spell them differently
# (Evaluation_Company vs evaluationCompany, Id vs id vs SystemId).
COMPANY_PICK=$(echo "$COMPANIES_JSON" | py3 -c "
import sys, json
want = sys.argv[1]
rows = [{k.lower(): v for k, v in c.items()} for c in json.load(sys.stdin)['value']]
if not rows:
    sys.exit(0)
if want:
    chosen = next((r for r in rows if r.get('name', '') == want), None)
    if chosen is None:
        sys.stderr.write(
            'ERROR: company %r not found on this server. Available: %s\n'
            % (want, ', '.join(repr(r.get('name', '')) for r in rows))
        )
        sys.exit(1)
else:
    chosen = next(
        (r for r in rows if r.get('evaluation_company') or r.get('evaluationcompany')),
        rows[0],
    )
print('%s\t%s' % (chosen.get('name', ''), chosen.get('id', chosen.get('systemid', ''))))
" "$COMPANY") || exit 1
COMPANY_AUTO=${COMPANY_PICK%%$'\t'*}
COMPANY_ID=${COMPANY_PICK#*$'\t'}
[ -z "$COMPANY" ] && COMPANY="${COMPANY_AUTO:-CRONUS International Ltd.}"

if [ -z "$COMPANY_ID" ]; then
    for url in "${BASE_URL}/api/v2.0/companies" "${_API_FALLBACK}/api/v2.0/companies"; do
        COMPANY_ID=$(curl -sf --max-time 10 -u "$AUTH" "$url" 2>/dev/null \
            | py3 -c "import sys,json; ms=[{k.lower():v for k,v in c.items()} for c in json.load(sys.stdin)['value']]; [print(m.get('id',m.get('systemid',''))) for m in ms if m.get('name','')==sys.argv[1]]" "$COMPANY" 2>/dev/null || true)
        [ -n "$COMPANY_ID" ] && break
    done
fi
if [ -z "$COMPANY_ID" ]; then
    echo "ERROR: Could not get company ID for '$COMPANY'"
    exit 1
fi
echo "Company: $COMPANY ($COMPANY_ID)"

# === Determine API Base URL ===
API_PORT_BASE=""
for base in "${BASE_URL}" "$_API_FALLBACK"; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -u "$AUTH" \
        "${base}/api/custom/automation/v1.0/companies(${COMPANY_ID})/codeunitRunRequests" 2>/dev/null || echo "000")
    [ "$HTTP" = "200" ] && API_PORT_BASE="$base" && break
done
if [ -z "$API_PORT_BASE" ]; then
    for base in "${BASE_URL}" "$_API_FALLBACK"; do
        T=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -u "$AUTH" "${base}/api/v2.0/companies" 2>/dev/null || echo "000")
        [ "$T" = "200" ] && API_PORT_BASE="$base" && break
    done
    [ -z "$API_PORT_BASE" ] && API_PORT_BASE="$BASE_URL"
fi
API_BASE="${API_PORT_BASE}/api/custom/automation/v1.0/companies(${COMPANY_ID})"

# Source the shared publish helper. Both this script and downstream
# consumers (e.g. bc-copilot-blueprint's iterate.sh) call into the same
# function so the 422-body-inspection / "missing dependency" logic only
# lives in one place.
# shellcheck disable=SC1091
. "$REPO_DIR/scripts/publish-app.sh"

# === Ensure TestRunnerExtension Published ===
echo -n "Checking TestRunner API... "
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -u "$AUTH" "${API_BASE}/codeunitRunRequests" 2>/dev/null || echo "000")
if [ "$HTTP" = "200" ]; then
    echo "available"
else
    echo "not found, publishing..."
    bc_publish_app "$TEST_RUNNER_APP" "$DEV_URL" "$AUTH" || exit 1
    echo -n "  Waiting for API..."
    for i in $(seq 1 30); do
        sleep 2
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -u "$AUTH" "${API_BASE}/codeunitRunRequests" 2>/dev/null || echo "000")
        [ "$HTTP" = "200" ] && break
        echo -n "."
    done
    echo ""
    [ "$HTTP" != "200" ] && echo "ERROR: TestRunner API not available" && exit 1
    echo "  API ready"
fi

# === Publish Test App (if provided) ===
if [ -n "$APP_FILE" ] && [ -f "$APP_FILE" ]; then
    echo -n "Publishing $(basename "$APP_FILE")... "
    if bc_publish_app "$APP_FILE" "$DEV_URL" "$AUTH"; then
        echo "OK"
    else
        # bc_publish_app already printed the diagnostic body and likely
        # cause hints; just bail.
        exit 1
    fi
fi

# === Discover Test Codeunit IDs ===
#
# Strategy: when an --app is provided, ALWAYS read SymbolReference.json from
# the .app and extract the actual Test codeunit IDs. If --codeunit-range is
# *also* provided, intersect the discovered IDs with that range. This avoids
# the SetupSuite iterating tens of thousands of nonexistent IDs (each
# AddTestCodeunit call costs ~3-5 SQL ops, so a literal "50000-99999" range
# expands to ~250k SQL ops, which times out long before completing).
#
# When only --codeunit-range is provided (no .app to discover from), fall
# back to the literal range — this is for ad-hoc usage and large
# Microsoft-shipped test apps where the .app may not be on the host.
CODEUNIT_IDS=""

# Parse --codeunit-range into a normalized "lo-hi,lo-hi,id,..." form.
#
# Accepted user-facing input shapes:
#   "50000"                            single id
#   "50000..70000"                     single AL range
#   "50000..50100|130450..130459"      multiple ranges (pipe-separated)
#   "50000,50001,50002"                explicit ids (comma-separated)
#   "50000..50100,130450,200000..210000"  mixed
#
# Normalization (so the Python filter below sees one canonical form):
#   1. Replace `|` separator with `,` so all parts join into one list
#   2. Replace `..` AL range syntax with `-` so each part is `lo-hi` or `id`
#
# The Python parser at the discovery step already loops over comma-separated
# parts and handles `lo-hi` ranges and bare ids; this is just the bash side.
NORMALIZED_RANGE=""
if [ -n "$CODEUNIT_RANGE" ]; then
    NORMALIZED_RANGE=$(printf '%s' "$CODEUNIT_RANGE" | sed -e 's/|/,/g' -e 's/\.\./-/g')
fi

if [ -n "$APP_FILE" ] && [ -f "$APP_FILE" ]; then
    echo -n "Discovering test codeunits from $(basename "$APP_FILE")"
    [ -n "$NORMALIZED_RANGE" ] && echo -n " (filter: $NORMALIZED_RANGE)"
    echo -n "... "
    CODEUNIT_IDS=$(unzip -p "$APP_FILE" SymbolReference.json 2>/dev/null | RANGE="$NORMALIZED_RANGE" py3 -c "
import os, sys, json
raw = sys.stdin.read()
if not raw.strip(): sys.exit(0)
data = json.loads(raw.lstrip('\ufeff'))

# Parse the optional range filter into (lo, hi) spans and check membership
# by interval containment — NOT by materializing a set of every ID in the
# range. A literal range like the AL-Go 'run everything' sentinel
# ('1-2147483647') would otherwise mean building a ~2 billion-element
# Python set, which OOMs the host in seconds. Spans keep membership checks
# O(1) per codeunit regardless of how wide the range is.
filt = os.environ.get('RANGE', '').strip()
spans = None  # None = no filter
if filt:
    spans = []
    for part in filt.split(','):
        part = part.strip()
        if not part:
            continue
        if '-' in part:
            lo, hi = part.split('-', 1)
            try:
                spans.append((int(lo), int(hi)))
            except ValueError:
                pass
        else:
            try:
                v = int(part)
                spans.append((v, v))
            except ValueError:
                pass

def in_spans(cuid):
    return any(lo <= cuid <= hi for lo, hi in spans)

ids = []
def collect(node):
    for cu in node.get('Codeunits', []):
        props = {p['Name']: p['Value'] for p in cu.get('Properties', [])}
        if props.get('Subtype') != 'Test':
            continue
        cuid = cu.get('Id')
        if spans is not None and not in_spans(cuid):
            continue
        ids.append(str(cuid))
    for ns in node.get('Namespaces', []):
        collect(ns)
collect(data)
print(','.join(ids))
" 2>/dev/null || true)
    echo "${CODEUNIT_IDS:-none found}"
fi

# Fall back to literal range expansion if no .app was provided.
if [ -z "$CODEUNIT_IDS" ] && [ -n "$NORMALIZED_RANGE" ] && [ -z "$APP_FILE" ]; then
    CODEUNIT_IDS="$NORMALIZED_RANGE"
fi

if [ -z "$CODEUNIT_IDS" ]; then
    echo "ERROR: No test codeunits found. Provide --app (with test codeunits in the symbol) or --codeunit-range"
    exit 1
fi
echo "Test codeunits: $CODEUNIT_IDS"

# === Split the codeunit list into parts BC's API will accept ===
#
# The suite is populated by POSTing the codeunit ids as ONE string field,
# `CodeunitIds: Text[2048]` on table 99903. Past 2048 characters BC rejects
# the POST with HTTP 400 Application_StringExceededLength and the run dies
# before a single test executes — nothing has failed, the list is simply too
# long. StefanMaron/BusinessCentral.AL.Language.Tests walked into that on
# 2026-09-05 at 342 test codeunits / 2051 characters, three over.
#
# So: split the list for the POST, and accumulate the parts into ONE suite.
# The first part calls setupSuite (which clears the suite), every part after
# it calls setupSuiteAppend (which does not). The whole suite then runs in a
# single TestRunner process, and therefore a single client session.
#
# It used to run one TestRunner process per part, because SetupSuite was the
# only action and it cleared the suite. That made session-scoped state —
# SingleInstance codeunit instances above all — restart at every part
# boundary, so a cross-codeunit SingleInstance test passed or failed
# depending on which part its codeunits landed in, with nothing in the output
# saying so. Issue #74; #65 is the same defect one level down.
#
# Parts are contiguous slices in discovery order, so the execution order is
# the same as an un-batched run's.
#
# scripts/chunk-codeunit-ids.py owns the split and proves it is total (nothing
# dropped, duplicated or reordered) before returning; `--self-test` exercises
# that without a BC container. The default budget is well under 2048 on
# purpose — see DEFAULT_MAX_CHARS there.
CODEUNIT_IDS_MAX_CHARS="${BC_CODEUNIT_IDS_MAX_CHARS:-1000}"
CHUNKS=()
CHUNK_LIST_FILE=$(mktemp)
CHUNK_SPLIT_RC=0
py3 "$REPO_DIR/scripts/chunk-codeunit-ids.py" \
    --max-chars "$CODEUNIT_IDS_MAX_CHARS" "$CODEUNIT_IDS" > "$CHUNK_LIST_FILE" || CHUNK_SPLIT_RC=$?
if [ "$CHUNK_SPLIT_RC" -ne 0 ]; then
    echo "ERROR: could not split the codeunit id list into API-sized parts (rc=$CHUNK_SPLIT_RC)"
    echo "       List was ${#CODEUNIT_IDS} chars: $CODEUNIT_IDS"
    rm -f "$CHUNK_LIST_FILE"
    exit 1
fi
# Read the whole list into an array BEFORE the execution loop. The loop body
# runs curl and `docker compose exec`, and a child that reads stdin would eat
# the rest of a `while read` redirection — the loop would then run once and
# look like it had run to completion.
while IFS= read -r _chunk_line; do
    [ -n "$_chunk_line" ] && CHUNKS+=("$_chunk_line")
done < "$CHUNK_LIST_FILE"
rm -f "$CHUNK_LIST_FILE"
if [ ${#CHUNKS[@]} -eq 0 ]; then
    echo "ERROR: codeunit id split produced no parts"
    exit 1
fi
if [ ${#CHUNKS[@]} -gt 1 ]; then
    echo "Codeunit id list is ${#CODEUNIT_IDS} chars; BC's CodeunitIds field holds 2048."
    echo "Posting the suite in ${#CHUNKS[@]} parts of at most ${CODEUNIT_IDS_MAX_CHARS} chars each; it runs as one."
fi

# === Setup Test Suite via OData (one call per part) ===
REQUEST_ID=""
# $3 is the bound action to call: setupSuite for the first part (clears the
# suite), setupSuiteAppend for every part after it (adds to it).
setup_suite_chunk() {
    local chunk="$1" label="$2" action="${3:-setupSuite}"
    echo -n "Setting up test suite${label}... "
    local create_body create_http
    create_body=$(mktemp)
    create_http=$(curl -s -o "$create_body" -w "%{http_code}" --max-time 15 -u "$AUTH" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"CodeunitIds\": \"$chunk\"}" \
        "${API_BASE}/codeunitRunRequests" 2>/dev/null)
    REQUEST_ID=$(py3 -c "import sys,json; print(json.load(sys.stdin)['Id'])" < "$create_body" 2>/dev/null || true)

    if [ -z "$REQUEST_ID" ]; then
        echo "FAIL (could not create request)"
        echo ""
        echo "ERROR: POST ${API_BASE}/codeunitRunRequests"
        echo "       HTTP code: $create_http"
        echo "       Request body: {\"CodeunitIds\": \"$chunk\"}"
        echo "       CodeunitIds length: ${#chunk} chars (BC's field limit is 2048)"
        echo "       Response body:"
        sed 's/^/         /' "$create_body"
        echo ""
        echo "       Likely causes:"
        echo "         - The custom TestRunner extension (page 99902 'Codeunit Run Requests')"
        echo "           is not installed for the default tenant. Check 'Test Runner Extension'"
        echo "           in entrypoint.sh's BC startup logs."
        echo "         - The OData endpoint we're hitting (\$API_PORT_BASE) is wrong for"
        echo "           POST in this BC version (the auto-detection picked an endpoint that"
        echo "           accepts GET on this path but not POST)."
        echo "         - The request body schema doesn't match the page's bound action."
        echo "         - Application_StringExceededLength above means the part is still"
        echo "           too long — lower BC_CODEUNIT_IDS_MAX_CHARS (currently"
        echo "           ${CODEUNIT_IDS_MAX_CHARS})."
        rm -f "$create_body"
        return 1
    fi
    rm -f "$create_body"

    local setup_http setup_body
    setup_body=$(mktemp)
    setup_http=$(curl -s -o "$setup_body" -w "%{http_code}" --max-time 60 -u "$AUTH" -X POST \
        "${API_BASE}/codeunitRunRequests(${REQUEST_ID})/Microsoft.NAV.${action}" 2>/dev/null)
    if [ "$setup_http" != "200" ] && [ "$setup_http" != "204" ]; then
        echo "FAIL (HTTP $setup_http)"
        echo "       Action: Microsoft.NAV.${action}"
        sed 's/^/       /' "$setup_body"
        # setupSuiteAppend arrived in Test Runner Extension 3.2.0.0. A 404 on
        # it means the container is older than this script — the extension is
        # baked into the bc-runner image, so the two move together. Say that,
        # because "HTTP 404" on its own points nowhere.
        if [ "$action" = "setupSuiteAppend" ] && [ "$setup_http" = "404" ]; then
            echo ""
            echo "       The bc-runner image is older than this script."
            echo "       Its Test Runner Extension has no setupSuiteAppend, which"
            echo "       this script needs to post a codeunit list too long for"
            echo "       one 2048-character CodeunitIds field (${#CODEUNIT_IDS} chars here)."
            echo "       Pull a current image, or pin scripts and runner_image to"
            echo "       the same bc-linux commit."
        fi
        rm -f "$setup_body"
        return 1
    fi
    # The action returns false when it parsed nothing out of CodeunitIds. Only
    # the append path checks it: the first part is checked far more strictly by
    # verify_suite_populated below, and an older extension version that has no
    # setupSuiteAppend fails on the HTTP code above, not here.
    if [ "$action" = "setupSuiteAppend" ] && grep -q '"value" *: *false' "$setup_body" 2>/dev/null; then
        echo "FAIL (the extension added none of this part's codeunits)"
        rm -f "$setup_body"
        return 1
    fi
    rm -f "$setup_body"
    return 0
}

# === Verify the suite was populated ===
#
# setupSuite returns 200 even when it ended up populating the suite with
# zero codeunits. That happens when the test app was published just before
# this script ran but BC's metadata cache hasn't propagated the new
# codeunits to the test framework yet — a race we've observed when
# run-tests.sh is invoked back-to-back from a fast inner loop like
# bc-copilot-blueprint's iterate.sh.
#
# Diagnostic signature of the race: TestRunner.dll runs and prints
# "0 total, 0 passed, 0 failed" in 0 seconds, then exits 1.
#
# Fix: query the testResults endpoint (which exposes Test Method Line
# rows from the suite). If empty, re-call setupSuite up to a handful of
# times with a small delay — usually the metadata catches up within a
# second or two.
VERIFY_LAST_RESPONSE=""
VERIFY_LAST_DETAIL=""
verify_suite_populated() {
    local req_id="$1"
    local expected_ids="$2"   # comma-separated codeunit IDs we care about
    # Up to 20 attempts × 2s sleep = ~40s of patience. The race the loop
    # is guarding against (publish → install → metadata propagation) is
    # usually <5s on a normal runner, but can stretch on faster I/O
    # environments where there is no accidental slack between publish
    # and the first setupSuite call.
    #
    # Stricter than "any row exists in DEFAULT": only counts FUNCTION-type
    # rows that mention OUR expected codeunit IDs. setupSuite inserts a
    # placeholder Codeunit-type row even when the test app's metadata
    # isn't loaded (so the codeunit registration exists but with zero
    # [Test] functions). Without filtering by line type the lenient
    # check accepts those stubs and lets the runner produce "0 results"
    # silently — exactly the failure mode we're guarding against.
    local attempt
    for attempt in $(seq 1 20); do
        VERIFY_LAST_RESPONSE=$(curl -sf --max-time 10 -u "$AUTH" \
            "${API_BASE}/testResults?\$filter=testSuite%20eq%20%27DEFAULT%27%20and%20lineType%20eq%20%27Function%27&\$top=500" 2>/dev/null || true)
        if [ -n "$VERIFY_LAST_RESPONSE" ]; then
            VERIFY_LAST_DETAIL=$(echo "$VERIFY_LAST_RESPONSE" | EXPECTED="$expected_ids" py3 -c "
import os, sys, json
try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f'parse-error: {e}'); sys.exit(0)
rows = data.get('value', [])
# Only Function-type rows count — Codeunit-type rows are populated by
# setupSuite even when the actual codeunit metadata isn't loaded.
present = {str(r.get('testCodeunit', '')).strip() for r in rows if r.get('testCodeunit')}
expected = {x.strip() for x in os.environ.get('EXPECTED', '').split(',') if x.strip()}
matched = present & expected
print(f'function_rows={len(rows)} distinct_codeunits={len(present)} expected={len(expected)} matched={len(matched)} sample={sorted(present)[:5]}')
sys.exit(0 if matched else 1)
" 2>&1)
            local rc=$?
            echo "  [verify attempt $attempt] $VERIFY_LAST_DETAIL"
            if [ "$rc" = "0" ]; then
                return 0
            fi
        else
            echo "  [verify attempt $attempt] testResults endpoint returned no body (curl failed)"
        fi
        # Suite still empty for our codeunits — re-call setupSuite. The
        # metadata may have synced since the previous attempt.
        curl -s -o /dev/null --max-time 60 -u "$AUTH" -X POST \
            "${API_BASE}/codeunitRunRequests(${req_id})/Microsoft.NAV.setupSuite" 2>/dev/null
        sleep 2
    done
    return 1
}

report_verify_failure() {
    local chunk="$1"
    echo ""
    echo "ERROR: setupSuite returned 200 but the DEFAULT test suite never"
    echo "       contained any of the expected codeunits after 20 retries (~40s)."
    echo ""
    echo "       Expected codeunit IDs: $chunk"
    echo ""
    echo "       Last verify detail:    $VERIFY_LAST_DETAIL"
    echo ""
    echo "       Last raw testResults response (truncated to 800 chars):"
    echo "         URL: ${API_BASE}/testResults?\$filter=testSuite%20eq%20'DEFAULT'&\$top=500"
    echo "         Body: ${VERIFY_LAST_RESPONSE:0:800}"
    echo ""
    echo "       Possible causes:"
    echo "         - Test app failed to install for the default tenant"
    echo "           (publish succeeds without installing in some tenant configurations)"
    echo "         - Expected codeunit IDs are not in the published .app"
    echo "         - setupSuite is reading from a different tenant than testResults"
    echo "         - The test framework republish step in entrypoint.sh failed silently"
    echo ""
    echo "       Cross-check installed extensions:"
    echo "         curl -u $AUTH '${BASE_URL}/api/v2.0/extensionDeployments'"
    echo "         curl -u $AUTH '${_API_FALLBACK}/api/v2.0/extensionDeployments'"
}

# === Disable Known-Failing Tests ===
#
# Parsed once, applied once — after the whole suite is populated and before
# it runs. It used to be applied once per part, because each part's setupSuite
# call deleted the DEFAULT suite's Test Method Line rows and with them the
# Run=false flags an earlier part had set. Nothing clears the suite mid-setup
# any more, so one application at the end covers every part.
DISABLED_ENTRIES=""
DISABLED_FILE_COUNT=0
if [ -n "$DISABLED_TESTS_DIR" ] && [ -d "$DISABLED_TESTS_DIR" ]; then
    # Read each DisabledTests JSON file individually (concatenating produces invalid JSON)
    # BCApps format per file: [{"codeunitId": 132920, "method": "TestName"}, ...]
    DISABLED_ENTRIES=$(py3 -c "
import json, glob, os, sys

pairs = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*.json'))):
    try:
        with open(f) as fh:
            entries = json.load(fh)
        if not isinstance(entries, list):
            entries = [entries]
        for e in entries:
            cu = e.get('codeunitId', 0)
            method = e.get('method', e.get('Method', ''))
            if cu and method:
                pairs.append(f'{cu}:{method}')
    except Exception as ex:
        pass

# Split into chunks of max 2000 chars (API field limit)
chunks, current = [], ''
for p in pairs:
    if len(current) + len(p) + 1 > 2000:
        chunks.append(current)
        current = p
    else:
        current = f'{current},{p}' if current else p
if current:
    chunks.append(current)
for c in chunks:
    print(c)
" "$DISABLED_TESTS_DIR" 2>/dev/null)
    DISABLED_FILE_COUNT=$(find "$DISABLED_TESTS_DIR" -name '*.json' | wc -l)
    echo "Parsed disabled tests from $DISABLED_FILE_COUNT files"
fi

# Same reason as the part list above: materialise into an array first, so
# nothing inside the apply loop can eat the input stream.
DISABLED_CHUNKS=()
if [ -n "$DISABLED_ENTRIES" ]; then
    while IFS= read -r _dis_line; do
        [ -n "$_dis_line" ] && DISABLED_CHUNKS+=("$_dis_line")
    done <<< "$DISABLED_ENTRIES"
fi

apply_disabled_tests() {
    [ ${#DISABLED_CHUNKS[@]} -eq 0 ] && return 0
    local applied=0 dis_chunk dis_resp dis_id
    for dis_chunk in "${DISABLED_CHUNKS[@]}"; do
        dis_resp=$(curl -s --max-time 15 -u "$AUTH" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"CodeunitIds\": \"$dis_chunk\"}" \
            "${API_BASE}/codeunitRunRequests" 2>/dev/null)
        dis_id=$(echo "$dis_resp" | py3 -c "import sys,json; print(json.load(sys.stdin)['Id'])" 2>/dev/null || true)
        if [ -n "$dis_id" ]; then
            curl -s -o /dev/null --max-time 30 -u "$AUTH" -X POST \
                "${API_BASE}/codeunitRunRequests(${dis_id})/Microsoft.NAV.disableTests" 2>/dev/null
            applied=$((applied + 1))
        fi
    done
    echo "Disabled tests: $applied chunk(s) from $DISABLED_FILE_COUNT file(s)"
    return 0
}

# === Execute Tests via WebSocket ===
echo ""
echo "=== Running Tests ==="

# Extract host from BASE_URL for WebSocket and API connections.
# Reuses _URL_ORIGIN (scheme://host) parsed earlier.
BC_HOST=$(echo "$_URL_ORIGIN" | sed 's|http[s]*://||')
[ -z "$BC_HOST" ] && BC_HOST="localhost"
WS_HOST="${BC_HOST}:7085"
ODATA_HOST="${BC_HOST}:7052"

# Parse auth components
AUTH_USER="${AUTH%%:*}"
AUTH_PASS="${AUTH#*:}"

# Note: do NOT pass --codeunit-filter here — the suite is already set up via OData.
# Passing it would re-trigger SetupSuite which clears test results.
# We pass --num-codeunits for correct progress display only.
#
# TestRunner execution strategy:
#   1. If a bc-linux docker compose stack is running, run TestRunner INSIDE the
#      bc container via `docker compose exec`. This requires NO host-side .NET 8
#      SDK because the container already has the runtime and the pre-built
#      TestRunner.dll at /bc/tools/TestRunner/. Works regardless of whether
#      BC_HOST is localhost, 127.0.0.1, or a docker bridge IP like 172.17.0.1
#      (e.g. when called from a devcontainer / Codespace).
#   2. Otherwise, try a pre-built TestRunner.dll on the host (no SDK needed).
#   3. Last resort: `dotnet run` against the source project (needs .NET 8 SDK).
USE_DOCKER_EXEC=false
HOST_PREBUILT=""
DOCKER_BC_CONTAINER=""
if command -v docker >/dev/null 2>&1; then
    # Try to find a running bc container in the bc-linux compose project.
    DOCKER_BC_CONTAINER=$(cd "$REPO_DIR" 2>/dev/null && docker compose ps -q bc 2>/dev/null | head -1)
    if [ -n "$DOCKER_BC_CONTAINER" ]; then
        # Verify TestRunner.dll is bundled in the image. Older bc-runner
        # images (built before this change) don't have it; in that case
        # we fall through to the host-side paths.
        if (cd "$REPO_DIR" 2>/dev/null && docker compose exec -T bc test -f /bc/tools/TestRunner/TestRunner.dll 2>/dev/null); then
            USE_DOCKER_EXEC=true
        else
            echo "[run-tests] bc-runner image does not bundle TestRunner.dll — trying host-side paths."
            echo "[run-tests]   (rebuild with 'docker compose build bc' to drop the host SDK requirement.)"
        fi
    fi
fi
# Check for a pre-built binary on the host (from a previous `dotnet publish`).
if [ "$USE_DOCKER_EXEC" = "false" ]; then
    for candidate in \
        "$REPO_DIR/tools/TestRunner/bin/Release/net8.0/publish/TestRunner.dll" \
        "$REPO_DIR/tools/TestRunner/bin/Release/net8.0/TestRunner.dll"; do
        if [ -f "$candidate" ]; then
            HOST_PREBUILT="$candidate"
            break
        fi
    done
fi
if [ "$USE_DOCKER_EXEC" = "false" ] && [ -z "$HOST_PREBUILT" ] && ! command -v dotnet >/dev/null 2>&1; then
    echo "ERROR: cannot run TestRunner — no execution method available."
    echo "  Tried (in order):"
    echo "    1. docker compose exec bc (container not found or missing TestRunner.dll)"
    echo "    2. Pre-built binary at tools/TestRunner/bin/Release/net8.0/ (not found)"
    echo "    3. dotnet run (dotnet SDK not installed)"
    echo ""
    echo "  Fix: start BC via 'docker compose up -d --wait', or run 'dotnet publish -c Release'"
    echo "  in tools/TestRunner/, or install .NET 8 SDK."
    exit 1
fi

# Runs the suite. $1 = codeunit count (for the runner's progress display and
# its own "did every codeunit run" check), $2 = where to write the JUnit XML,
# $3 = the run's timeout in minutes. Always writes JUnit, even when the caller
# did not ask for a file: the completeness check below needs it to prove no
# codeunit went missing.
execute_chunk() {
    local num_codeunits="$1" junit_path="$2" timeout_min="${3:-$TIMEOUT_MIN}"
    local max_iter=$(( num_codeunits * 3 + 20 ))
    local rc=0
    mkdir -p "$(dirname "$junit_path")"
    rm -f "$junit_path"
    if [ "$USE_DOCKER_EXEC" = "true" ]; then
        # Inside the container, BC's WebSocket and API ports are local to the
        # container itself, so always use localhost regardless of how the host
        # has them mapped. The TestRunner.dll path is fixed by the Dockerfile.
        #
        # --verbose is now passed by default. Without it, every Log() message
        # in TestRunner.dll is silently swallowed (the function gates on a
        # `verbose` flag and writes to stderr only when set). That made the
        # bc-copilot-blueprint debugging session needlessly painful: the
        # runner would exit with "0 total, 0 passed, 0 failed" in 0 seconds
        # and there was no way to see *why* — whether it was a connection
        # failure, an empty suite, "All tests executed" on the first iter,
        # or anything else. Verbose stderr is cheap and the right default.
        #
        # JUnit output: TestRunner writes to a path inside the container,
        # which we then read back to the host path. Avoids needing to
        # bind-mount the destination. A run that failed to write its report
        # fails the read, and the completeness step turns that into a loud
        # error rather than a stale or duplicated result set — so a report
        # left behind by an earlier run in the same container is removed first.
        local in_container_junit="/tmp/$(basename "$junit_path")"
        ( cd "$REPO_DIR" && docker compose exec -T bc rm -f "$in_container_junit" </dev/null )
        local renew_flag=(); if [ "$RENEW_CLIENT_CONTEXT" = "1" ]; then renew_flag=(--renew-client-context); fi
        ( cd "$REPO_DIR" && printf '%s' "$AUTH_PASS" | docker compose exec -T bc \
            env DOTNET_STARTUP_HOOKS= dotnet /bc/tools/TestRunner/TestRunner.dll \
            --verbose \
            --host "localhost:7085" \
            --odata-host "localhost:7052" \
            --company "$COMPANY" \
            --user "$AUTH_USER" \
            --password-stdin \
            --suite "DEFAULT" \
            --num-codeunits "$num_codeunits" \
            --timeout "$timeout_min" \
            --codeunit-timeout 10 \
            --max-iterations "$max_iter" \
            "${renew_flag[@]}" \
            --junit-output "$in_container_junit" )
        rc=$?
        # Read the report with `exec cat`, not `docker compose cp`: on a
        # rootless daemon `cp` fails outright for any container with a
        # read-only bind mount (the license mount is one, even as /dev/null),
        # because the daemon cannot remount it read-only in its own namespace.
        #
        # </dev/null: `docker compose exec` inherits this script's stdin, and
        # run-tests.sh is itself called from a `while read ... done <<<` loop
        # in bc-test-from-source.yml. A child that reads stdin eats the rest
        # of that here-string and the caller's loop silently runs once.
        if ( cd "$REPO_DIR" && docker compose exec -T bc cat "$in_container_junit" </dev/null >"$junit_path" 2>/dev/null ); then
            echo "[run-tests] JUnit XML copied to $junit_path"
        else
            rm -f "$junit_path"
            echo "[run-tests] WARN: TestRunner did not produce $in_container_junit inside the container"
        fi
    elif [ -n "$HOST_PREBUILT" ]; then
        # Pre-built binary on the host — no SDK needed, just the .NET 8 runtime.
        echo "[run-tests] Using pre-built TestRunner at $HOST_PREBUILT"
        local renew_flag=(); if [ "$RENEW_CLIENT_CONTEXT" = "1" ]; then renew_flag=(--renew-client-context); fi
        printf '%s' "$AUTH_PASS" | dotnet "$HOST_PREBUILT" \
            --verbose \
            --host "$WS_HOST" \
            --odata-host "$ODATA_HOST" \
            --company "$COMPANY" \
            --user "$AUTH_USER" \
            --password-stdin \
            --suite "DEFAULT" \
            --num-codeunits "$num_codeunits" \
            --timeout "$timeout_min" \
            --codeunit-timeout 10 \
            --max-iterations "$max_iter" \
            "${renew_flag[@]}" \
            --junit-output "$junit_path"
        rc=$?
    else
        local renew_flag=(); if [ "$RENEW_CLIENT_CONTEXT" = "1" ]; then renew_flag=(--renew-client-context); fi
        printf '%s' "$AUTH_PASS" | dotnet run --project "$REPO_DIR/tools/TestRunner" -v q -- \
            --verbose \
            --host "$WS_HOST" \
            --odata-host "$ODATA_HOST" \
            --company "$COMPANY" \
            --user "$AUTH_USER" \
            --password-stdin \
            --suite "DEFAULT" \
            --num-codeunits "$num_codeunits" \
            --timeout "$timeout_min" \
            --codeunit-timeout 10 \
            --max-iterations "$max_iter" \
            "${renew_flag[@]}" \
            --junit-output "$junit_path"
        rc=$?
    fi
    return $rc
}

# === Code coverage ===
#
# Coverage is recorded by the extension's Coverage Recorder in the test session
# (a log started from an OData request belongs to that request's session and
# sees none of the tests). startCoverageForApps names the apps under test, so
# the denominator is their code and the report lists untouched objects at 0%;
# an older extension only has startCoverage, which records every loaded partner
# object (legacy mode; a 3.4 extension's report has no function data). The
# extension keeps the whole run as one text report (docs/CODE-COVERAGE.md); scripts/coverage_report.py turns it
# into the CSV, Cobertura and LCOV files. Never fails the run: coverage is a
# report about the tests, not one of them.
COVERAGE_APP_IDS=""

# Fills COVERAGE_APP_IDS (comma separated) and prints the scope.
resolve_coverage_apps() {
    local ids="" id name resolved
    if [ ${#COVERAGE_APPS[@]} -gt 0 ]; then
        for id in "${COVERAGE_APPS[@]}"; do
            # The id goes into a JSON body; only a GUID is accepted.
            if ! [[ "$id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
                echo "WARN: --coverage-app '$id' is not a GUID; ignored."
                continue
            fi
            ids="${ids:+$ids,}$(echo "$id" | tr 'A-Z' 'a-z')"
        done
        COVERAGE_APP_IDS="$ids"
        if [ -n "$ids" ]; then
            echo "Coverage scope (--coverage-app): $ids"
            return 0
        fi
        echo "Coverage scope: none of the --coverage-app values is a GUID."
        return 0
    fi
    if [ -z "$APP_FILE" ] || [ ! -f "$APP_FILE" ]; then
        echo "Coverage scope: empty (no --app test app to read dependencies from, no --coverage-app)."
        return 0
    fi
    # The apps under test are the test app's own dependencies, minus Microsoft's
    # apps and test libraries (name contains "test"): those are tools, and their
    # code running is incidental.
    resolved=$(py3 - "$SCRIPT_DIR" "$APP_FILE" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from _bcapp import read_app_info
info = read_app_info(sys.argv[2])
if info is None:
    sys.exit(0)
for d in info["dependencies"]:
    if d["publisher"].strip().lower() == "microsoft":
        continue
    if "test" in d["name"].lower():
        continue
    print(d["id"] + "\t" + (d["name"] or d["id"]))
PYEOF
)
    if [ -z "$resolved" ]; then
        echo "Coverage scope: empty (the test app has no dependency that is neither Microsoft's nor a test library; pass --coverage-app)."
        return 0
    fi
    echo "Coverage scope (test app dependencies):"
    while IFS=$'\t' read -r id name; do
        echo "  $name ($id)"
        ids="${ids:+$ids,}$id"
    done <<< "$resolved"
    COVERAGE_APP_IDS="$ids"
}

# POSTs an OData action on the run request. Sets ACTION_HTTP and ACTION_FALSE:
# an action that failed inside the extension still answers 200 with {"value":false},
# so the body counts, not just the status.
coverage_action() {
    local name="$1" body="${2:-}" out
    local args=(-s -w $'\n%{http_code}' --max-time 120 -u "$AUTH" -X POST)
    [ -n "$body" ] && args+=(-H "Content-Type: application/json" -d "$body")
    out=$(curl "${args[@]}" "${API_BASE}/codeunitRunRequests(${REQUEST_ID})/Microsoft.NAV.${name}" 2>/dev/null)
    ACTION_HTTP="${out##*$'\n'}"
    ACTION_FALSE=0
    if [[ "${out%$'\n'*}" =~ \"value\"[[:space:]]*:[[:space:]]*false ]]; then
        ACTION_FALSE=1
    fi
    [ "$ACTION_HTTP" = "200" ] || [ "$ACTION_HTTP" = "204" ]
}

start_coverage() {
    resolve_coverage_apps
    if [ -n "$COVERAGE_APP_IDS" ]; then
        local action=startCoverageForApps rc=0
        local body="{\"appIds\":\"${COVERAGE_APP_IDS}\"}"
        if [ "$COVERAGE_ALL_SESSIONS" = 1 ]; then
            coverage_action startCoverageForAppsAllSessions "$body"; rc=$?
            if [ "$rc" -ne 0 ] && { [ "$ACTION_HTTP" = "400" ] || [ "$ACTION_HTTP" = "404" ]; }; then
                echo "WARN: startCoverageForAppsAllSessions not available (HTTP $ACTION_HTTP); the Test Runner Extension predates 4.1. Recording the test session only."
            else
                action=""
            fi
        fi
        [ -n "$action" ] && { coverage_action "$action" "$body"; rc=$?; }
        if [ "$rc" -eq 0 ]; then
            if [ "$ACTION_FALSE" = 0 ]; then
                echo "Code coverage recording started for the apps under test."
                return 0
            fi
            echo "WARN: startCoverageForApps returned false (the app ids may be too long for the extension). Falling back to legacy coverage of every loaded partner object."
        elif [ "$ACTION_HTTP" != "400" ] && [ "$ACTION_HTTP" != "404" ]; then
            echo "WARN: could not start code coverage (HTTP $ACTION_HTTP). Running without coverage."
            return 1
        else
            echo "WARN: startCoverageForApps not available (HTTP $ACTION_HTTP); the Test Runner Extension is older. Falling back to legacy coverage of every loaded partner object."
        fi
    else
        echo "Falling back to legacy coverage of every loaded partner object."
    fi
    if ! coverage_action startCoverage; then
        echo "WARN: could not start code coverage (HTTP $ACTION_HTTP); the Test Runner Extension may predate 3.4. Running without coverage."
        return 1
    fi
    if [ "$ACTION_FALSE" = 1 ]; then
        echo "WARN: startCoverage returned false. Running without coverage."
        return 1
    fi
    echo "Code coverage recording started (legacy mode)."
}

# Where report paths are relative to: --coverage-root, else the git toplevel of
# --coverage-source, else --coverage-source itself.
resolve_coverage_root() {
    [ -n "$COVERAGE_ROOT" ] && return 0
    [ -z "$COVERAGE_SOURCE" ] && return 0
    COVERAGE_ROOT=$(git -C "$COVERAGE_SOURCE" rev-parse --show-toplevel 2>/dev/null) || COVERAGE_ROOT=""
    [ -z "$COVERAGE_ROOT" ] && COVERAGE_ROOT="$COVERAGE_SOURCE"
    return 0
}

export_coverage() {
    local kind complete
    if ! coverage_action stopCoverage; then
        echo "WARN: could not stop code coverage (HTTP $ACTION_HTTP); no coverage written."
        return 0
    fi
    [ "$ACTION_FALSE" = 1 ] && echo "WARN: stopCoverage returned false; reading what was recorded anyway."
    COVERAGE_TMP=$(mktemp -d)
    # The directory goes away on any exit path, a signal included.
    trap 'rm -rf "$COVERAGE_TMP"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Reads the run. Writes report.txt (v2) or legacy.csv (legacy, the same bytes
    # the CSV has always had: header, CRLF) into the directory and prints
    # "<kind> <complete>"; kind "empty" means the extension answered with a v2
    # report field that holds nothing.
    if kind=$(py3 - "$API_BASE" "$AUTH" "$COVERAGE_TMP" <<'PYEOF'
import base64, csv, json, os, sys, urllib.error, urllib.request
api_base, auth, out = sys.argv[1:4]
header = {"Authorization": "Basic " + base64.b64encode(auth.encode()).decode()}
row = None
# Extension 3.4+ returns the whole run in one request; "report" (v2) only exists
# on the newest, "csv" on 3.4. Selecting a field the extension lacks is an error,
# so retry with fewer fields before giving up on the API.
for fields in ("generation,complete,report,csv", "complete,csv", "csv"):
    try:
        req = urllib.request.Request(api_base + "/coverageReports?$select=" + fields, headers=header)
        with urllib.request.urlopen(req, timeout=120) as r:
            value = json.load(r).get("value", [])
        row = value[0] if value else {}
        break
    except urllib.error.HTTPError as e:
        if e.code not in (400, 404):
            raise
if row is not None and "report" in row:
    # An empty report is an answer, not a missing field: the extension ran but
    # wrote nothing, so the legacy path below would only find nothing as well.
    if not row["report"]:
        print("empty unknown")
        sys.exit(0)
    with open(os.path.join(out, "report.txt"), "w", encoding="utf-8", newline="") as f:
        f.write(row["report"])
    c = row.get("complete")
    print("v2", "true" if c is True else "false" if c is False else "unknown")
    sys.exit(0)
path = os.path.join(out, "legacy.csv")
if row and "csv" in row:
    # Same bytes as the csv.writer below writes: CRLF line ends.
    with open(path, "w", newline="") as f:
        f.write("object_type,object_id,line_no,hits\r\n")
        for line in row["csv"].splitlines():
            if line:
                f.write(line + "\r\n")
    print("legacy unknown")
    sys.exit(0)
url = api_base + "/codeCoverageLines?$select=objectType,objectId,lineNo,hits"
with open(path, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["object_type", "object_id", "line_no", "hits"])
    while url:
        req = urllib.request.Request(url, headers=header)
        with urllib.request.urlopen(req, timeout=120) as r:
            page = json.load(r)
        for line in page.get("value", []):
            w.writerow([line["objectType"], line["objectId"], line["lineNo"], line["hits"]])
        url = page.get("@odata.nextLink")
print("legacy unknown")
PYEOF
    ); then
        :
    else
        echo "WARN: could not read code coverage; no coverage written."
        rm -rf "$COVERAGE_TMP"
        return 0
    fi
    kind="${kind##*$'\n'}"
    complete="${kind#* }"
    kind="${kind%% *}"
    if [ "$kind" = "empty" ]; then
        echo "NOTE: the Test Runner Extension wrote no coverage report: coverage never started in the test session. No coverage files written."
        rm -rf "$COVERAGE_TMP"
        return 0
    fi
    if [ "$complete" = "false" ]; then
        echo "WARN: coverage report incomplete (the run ended before the final write; hits since the last checkpoint are missing)."
    fi

    resolve_coverage_root
    local args=()
    [ -n "$COVERAGE_COBERTURA" ] && args+=(--cobertura "$COVERAGE_COBERTURA")
    [ -n "$COVERAGE_LCOV" ] && args+=(--lcov "$COVERAGE_LCOV")
    [ -n "$COVERAGE_SOURCE" ] && args+=(--source "$COVERAGE_SOURCE")
    [ -n "$COVERAGE_ROOT" ] && args+=(--root "$COVERAGE_ROOT")
    [ "$complete" != "unknown" ] && args+=(--complete "$complete")
    if [ "$kind" = "v2" ]; then
        [ -n "$COVERAGE_OUTPUT" ] && args+=(--csv-out "$COVERAGE_OUTPUT")
        args+=(--report "$COVERAGE_TMP/report.txt")
    else
        echo "NOTE: the Test Runner Extension returned no v2 report; Cobertura/LCOV (if asked for) carry lines only, classes named after objects."
        [ -n "$COVERAGE_OUTPUT" ] && cp "$COVERAGE_TMP/legacy.csv" "$COVERAGE_OUTPUT"
        args+=(--legacy-csv "$COVERAGE_TMP/legacy.csv")
    fi
    if py3 "$SCRIPT_DIR/coverage_report.py" "${args[@]}"; then
        [ -n "$COVERAGE_OUTPUT" ] && echo "Code coverage CSV written to $COVERAGE_OUTPUT"
        [ -n "$COVERAGE_COBERTURA" ] && echo "Cobertura written to $COVERAGE_COBERTURA"
        [ -n "$COVERAGE_LCOV" ] && echo "LCOV written to $COVERAGE_LCOV"
    else
        echo "WARN: could not convert the code coverage report; files may be missing."
    fi
    rm -rf "$COVERAGE_TMP"
    return 0
}

# --- Populate the suite, one part at a time ---
CHUNK_JUNIT_DIR=$(mktemp -d)
CHUNK_JUNITS=()
OVERALL_RC=0
CHUNKS_SETUP=0
RUN_START_TS=$(date +%s)

CHUNK_INDEX=0
for CHUNK in "${CHUNKS[@]}"; do
    CHUNK_INDEX=$((CHUNK_INDEX + 1))
    CHUNK_LABEL=""
    [ ${#CHUNKS[@]} -gt 1 ] && CHUNK_LABEL=" (part $CHUNK_INDEX/${#CHUNKS[@]})"

    if [ "$CHUNK_INDEX" -eq 1 ]; then
        if ! setup_suite_chunk "$CHUNK" "$CHUNK_LABEL" "setupSuite"; then
            rm -rf "$CHUNK_JUNIT_DIR"
            exit 1
        fi
        # Only the first part is verified against the server. The check exists
        # for the publish → install → metadata propagation race, which is a
        # property of the whole app rather than of one part: if the metadata
        # is not there yet, the first part cannot populate either. Its retry
        # re-calls setupSuite, which is why it has to run before anything has
        # been appended.
        echo ""   # newline so per-attempt logs are readable
        if ! verify_suite_populated "$REQUEST_ID" "$CHUNK"; then
            report_verify_failure "$CHUNK"
            rm -rf "$CHUNK_JUNIT_DIR"
            exit 1
        fi
        echo "Test suite populated${CHUNK_LABEL}."
    else
        if ! setup_suite_chunk "$CHUNK" "$CHUNK_LABEL" "setupSuiteAppend"; then
            rm -rf "$CHUNK_JUNIT_DIR"
            exit 1
        fi
        echo "added${CHUNK_LABEL}."
    fi
    CHUNKS_SETUP=$((CHUNKS_SETUP + 1))
done

# A part that never made it into the suite would look exactly like a smaller
# green run. Assert it directly rather than inferring it from the totals. The
# completeness check in merge-junit-batches.py catches the same thing from the
# other end, by codeunit rather than by part.
if [ "$CHUNKS_SETUP" -ne "${#CHUNKS[@]}" ]; then
    echo "ERROR: $CHUNKS_SETUP of ${#CHUNKS[@]} part(s) reached the suite — the rest never did"
    rm -rf "$CHUNK_JUNIT_DIR"
    exit 1
fi

apply_disabled_tests

# --- Run the whole suite in one client session ---
IFS=',' read -ra ALL_CU_ARRAY <<< "$CODEUNIT_IDS"
NUM_CODEUNITS=${#ALL_CU_ARRAY[@]}
RUN_JUNIT="$CHUNK_JUNIT_DIR/run.xml"
CHUNK_JUNITS+=("$RUN_JUNIT")
SESSION_NOTE=""
[ ${#CHUNKS[@]} -gt 1 ] && SESSION_NOTE=" (suite posted in ${#CHUNKS[@]} parts, run as one)"
echo "Executing $NUM_CODEUNITS codeunits via WebSocket${SESSION_NOTE}..."
# --timeout was a per-part budget when each part was its own process. Scale it
# by the number of parts so a suite that fit in the old total still fits.
COVERAGE_ON=0
[ -n "$COVERAGE_OUTPUT$COVERAGE_COBERTURA$COVERAGE_LCOV" ] && { start_coverage && COVERAGE_ON=1; }
execute_chunk "$NUM_CODEUNITS" "$RUN_JUNIT" "$(( TIMEOUT_MIN * ${#CHUNKS[@]} ))"
[ $? -ne 0 ] && OVERALL_RC=1
[ "$COVERAGE_ON" = 1 ] && export_coverage

# === Finish the report ===
#
# One run, so one input file — this step is now here for the completeness
# check rather than for the merge, and it still recomputes the roll-up
# attributes and normalizes the shape. Same output run-tests-hybrid.py
# produces, so downstream consumers cannot tell a suite posted in parts from
# one posted in a single request.
TOTAL_ELAPSED=$(( $(date +%s) - RUN_START_TS ))
MERGED_JUNIT="$JUNIT_OUTPUT"
[ -z "$MERGED_JUNIT" ] && MERGED_JUNIT="$CHUNK_JUNIT_DIR/merged.xml"

# STRICT_COMPLETENESS: when the list was posted in parts, a codeunit that
# produced no <testsuite> at all means a part was lost somewhere between the
# POST and the report, and that must fail the run (issue #57 is the same
# false-green shape). With a single part the check is reported but not fatal —
# nothing was split, so a missing codeunit is a pre-existing condition this
# change did not cause and must not newly re-verdict.
STRICT_COMPLETENESS=0
[ ${#CHUNKS[@]} -gt 1 ] && STRICT_COMPLETENESS=1

STRICT_FLAG=()
[ "$STRICT_COMPLETENESS" = "1" ] && STRICT_FLAG=(--strict)
py3 "$REPO_DIR/scripts/merge-junit-batches.py" \
    --out "$MERGED_JUNIT" \
    --expected "$CODEUNIT_IDS" \
    --elapsed "$TOTAL_ELAPSED" \
    "${STRICT_FLAG[@]}" \
    "${CHUNK_JUNITS[@]}"
MERGE_RC=$?
[ "$MERGE_RC" -ne 0 ] && OVERALL_RC=1

if [ -n "$JUNIT_OUTPUT" ] && [ -f "$JUNIT_OUTPUT" ]; then
    echo "JUnit XML written to $JUNIT_OUTPUT"
fi
rm -rf "$CHUNK_JUNIT_DIR"

exit $OVERALL_RC
