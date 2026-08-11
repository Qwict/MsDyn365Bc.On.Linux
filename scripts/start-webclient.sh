#!/bin/bash
# Self-host Microsoft's Business Central web client (Prod.Client.WebCoreApp)
# on Kestrel inside the bc container, pointed at the Linux NST.
#
# EXPERIMENTAL / PoC — see docs/WEBCLIENT-POC.md.
#
# Usage (inside the bc container):
#   /bc/scripts/start-webclient.sh [port]
# Or from the host:
#   docker compose exec bc /bc/scripts/start-webclient.sh
#
# Opt-in from docker compose: set BC_WEBCLIENT=1 (entrypoint starts it in the
# background after the NST is ready) and map port 8080.
set -e

PORT="${1:-${BC_WEBCLIENT_PORT:-8080}}"
ARTIFACTS="${ARTIFACTS:-/bc/artifacts}"
WEBCLIENT_DIR="${WEBCLIENT_DIR:-/bc/webclient}"
HOOK_DLL="/bc/webclient-hook/WebClientHook.dll"

# Optional path-prefix support for reverse proxies that route by path
# (single hostname/port, e.g. https://host:port/my-tier) rather than by
# hostname or port. HttpSysStub's UrlStrippingStartupFilter already strips
# a path component off the server address and calls UsePathBase() with it
# (see src/stubs/HttpSysStub/HttpSysStub.cs) — this just gives that a
# documented, first-class way in from docker compose. Normalize to a
# leading slash / no trailing slash; HttpSysStub trims a trailing slash
# itself, but the leading slash is required for Uri.AbsolutePath parsing.
PATHBASE="${BC_WEBCLIENT_PATHBASE:-}"
if [ -n "$PATHBASE" ]; then
    case "$PATHBASE" in
        /*) ;;
        *) PATHBASE="/$PATHBASE" ;;
    esac
    PATHBASE="${PATHBASE%/}"
fi

# Optional: tell the web client it is reached over HTTPS even though it speaks
# plain HTTP itself. Needed when TLS is terminated by a reverse proxy in front
# of the container: without it the client builds its redirects from its own
# scheme and emits "Location: http://<public-host>/SignIn", which the browser
# then follows in cleartext against a TLS-only port. Also makes BC mark its
# session cookies Secure. Off by default (direct http://localhost access).
REQUIRE_SSL="${BC_WEBCLIENT_REQUIRE_SSL:-false}"
case "$REQUIRE_SSL" in
    1|true|True|TRUE|yes) REQUIRE_SSL="true" ;;
    *) REQUIRE_SSL="false" ;;
esac

# Locate the WebPublish layout in the platform artifact
WEBPUBLISH=$(find "$ARTIFACTS/platform/WebClient" -maxdepth 5 -type d -name WebPublish 2>/dev/null | head -1)
if [ -z "$WEBPUBLISH" ]; then
    echo "[webclient] ERROR: WebPublish not found under $ARTIFACTS/platform/WebClient" >&2
    exit 1
fi

# Stage a writable copy (config + on-disk resource extraction need writes)
if [ ! -f "$WEBCLIENT_DIR/Prod.Client.WebCoreApp.dll" ]; then
    echo "[webclient] Staging $WEBPUBLISH -> $WEBCLIENT_DIR"
    mkdir -p "$WEBCLIENT_DIR"
    cp -r "$WEBPUBLISH/." "$WEBCLIENT_DIR/"
fi

# Resource directories the server expects (it checks them at startup; the
# Windows build creates them via the MSI installer)
mkdir -p "$WEBCLIENT_DIR/wwwroot/Resources/ExtractedResources" \
         "$WEBCLIENT_DIR/wwwroot/Resources/images/static" \
         "$WEBCLIENT_DIR/wwwroot/Thumbnails" \
         "$WEBCLIENT_DIR/wwwroot/Reports"

# Case-sensitivity fix: the boot view reads script files by lowercased name
# ("js/boot.js") but the artifact ships "js/Boot.js" etc.
(cd "$WEBCLIENT_DIR/wwwroot/js" && for f in *[A-Z]*; do
    lc=$(echo "$f" | tr 'A-Z' 'a-z')
    [ -e "$lc" ] || ln -s "$f" "$lc"
done)
# BrandProvider enumerates "Resources/Brand/..." but the artifact ships "brand"
[ -e "$WEBCLIENT_DIR/wwwroot/Resources/Brand" ] || ln -s brand "$WEBCLIENT_DIR/wwwroot/Resources/Brand"
# The FluentUI icon-font CSS requests "Resources/Fonts/fluentui/fabric-icons-*.woff"
# but the artifact ships "Resources/fonts/" — without this every glyph icon in the
# UI (action bar, chevrons, system tray) is missing.
[ -e "$WEBCLIENT_DIR/wwwroot/Resources/Fonts" ] || ln -s fonts "$WEBCLIENT_DIR/wwwroot/Resources/Fonts"

# Point the web client at the local NST (NavUserPassword over ws://localhost:7085)
python3 - "$WEBCLIENT_DIR" "$PORT" "$PATHBASE" "$REQUIRE_SSL" <<'PYEOF'
import json, sys
base = sys.argv[1]
port = sys.argv[2]
pathbase = sys.argv[3]
require_ssl = sys.argv[4]

# hosting.json wins over ASPNETCORE_URLS (the app calls UseUrls with it).
# The path component (if any) is stripped back off by HttpSysStub's
# UrlStrippingStartupFilter, which calls UsePathBase() with it.
json.dump({"urls": f"http://*:{port}{pathbase}"}, open(f"{base}/hosting.json", "w"), indent=2)

p = f"{base}/navsettings.json"
d = json.load(open(p, encoding="utf-8-sig"))
n = d["NAVWebSettings"]
n["Server"] = "localhost"
n["ServerInstance"] = "BC"
n["ClientServicesPort"] = "7085"
n["ClientServicesCredentialType"] = "NavUserPassword"
n["RequireSsl"] = require_ssl
n["ServerHttps"] = False
n["AuthenticateServer"] = "false"
json.dump(d, open(p, "w"), indent=2)

# The shipped runtimeconfig forces NLS globalization (Windows-only)
p = f"{base}/Prod.Client.WebCoreApp.runtimeconfig.json"
d = json.load(open(p, encoding="utf-8-sig"))
d["runtimeOptions"]["configProperties"]["System.Globalization.UseNls"] = False
json.dump(d, open(p, "w"), indent=2)
print("[webclient] navsettings.json + runtimeconfig.json patched")
PYEOF

echo "[webclient] Starting Prod.Client.WebCoreApp on http://0.0.0.0:$PORT${PATHBASE} (NST: localhost:7085, auth: NavUserPassword)"
cd "$WEBCLIENT_DIR"
# DOTNET_STARTUP_HOOKS: replace the NST hook with the web-client-specific one.
# The NST hook contains patches that assume the NST process and must not run here.
# HTTPSYS_STUB_INJECT_IDENTITY=0: the web client runs its own forms auth;
# the HttpSys stub's injected admin principal would bypass the sign-in page.
# DOTNET_TieredCompilation=0: JMP hooks must not be overwritten by Tier-1
# recompilation (same invariant as the NST hook).
exec env \
    DOTNET_STARTUP_HOOKS="$HOOK_DLL" \
    DOTNET_TieredCompilation=0 \
    DOTNET_SYSTEM_GLOBALIZATION_USENLS=0 \
    HTTPSYS_STUB_INJECT_IDENTITY=0 \
    ASPNETCORE_URLS="http://0.0.0.0:$PORT" \
    dotnet Prod.Client.WebCoreApp.dll
