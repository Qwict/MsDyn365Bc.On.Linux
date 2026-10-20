#!/usr/bin/env bash
# tenant.sh - add, remove and list tenants of a multitenant bc-runner (BC_MULTITENANT=1).
#
# Runs INSIDE the bc container:
#   docker compose exec -T bc /bc/scripts/tenant.sh add <id>
#   docker compose exec -T bc /bc/scripts/tenant.sh remove <id>
#   docker compose exec -T bc /bc/scripts/tenant.sh list
#
# A tenant is a database named <id> restored from the tenant template backup the
# entrypoint wrote (/var/opt/mssql/data/<BC_TENANT_TEMPLATE_DB>.bak on the SQL
# container) and registered by a row in [<app db>].dbo.[$ndo$tenants]. The running
# NST polls that table and mounts or dismounts without a restart. See MULTITENANT.md.
#
# Output: progress goes to stderr. The LAST stdout line of add/remove is one
# machine-readable line:
#     tenant.sh <command> ok id=<id> status=<status> seconds=<n>
#     tenant.sh <command> error id=<id> code=<exit code> reason=<text>
# `list` prints TSV on stdout: id<TAB>database<TAB>state, no header.
#
# Exit codes: 0 ok (also when already in the requested state), 2 bad arguments,
# 3 timed out waiting for the NST, 4 SQL error, 5 not a ready multitenant
# instance (BC_MULTITENANT off, or the template backup is not there yet),
# 6 the NST dropped the tenant's mount twice (the tenant database is kept for
# inspection; run remove to clean it up).
#
# Environment (all optional, defaults come from the container):
#   BC_TENANT_ADD_TIMEOUT     seconds to wait for a mount (default 180)
#   BC_TENANT_REMOVE_TIMEOUT  seconds to wait for the NST to dismount (default 60)
#   BC_TENANT_TEMPLATE_DB     template name (default tenant_template)

set -uo pipefail

SQLCMD_BIN=/opt/mssql-tools18/bin/sqlcmd
SQL_SERVER="${SQL_SERVER:-sql}"
BC_DB_USER="${BC_DB_USER:-bctest}"
BC_DB_PASSWORD="${BC_DB_PASSWORD:-Test1234}"
BC_SERVER_USERNAME="${BC_SERVER_USERNAME:-BCRUNNER}"
BC_SERVER_PASSWORD="${BC_SERVER_PASSWORD:-Admin123!}"
TEMPLATE_DB="${BC_TENANT_TEMPLATE_DB:-tenant_template}"
TEMPLATE_BAK="/var/opt/mssql/data/${TEMPLATE_DB}.bak"
DATA_DIR="/var/opt/mssql/data"
ADD_TIMEOUT="${BC_TENANT_ADD_TIMEOUT:-180}"
REMOVE_TIMEOUT="${BC_TENANT_REMOVE_TIMEOUT:-60}"
ODATA_URL="http://localhost:7048/BC/ODataV4/Company"
CONFIG="/bc/service/CustomSettings.config"
export SQLCMDPASSWORD="${SA_PASSWORD:-Passw0rd123!}"

CMD="${1:-}"
ID="${2:-}"
START=$(date +%s)

log() { echo "[tenant.sh] $*" >&2; }
elapsed() { echo $(( $(date +%s) - START )); }
fail() { # fail <code> <reason>
    echo "tenant.sh ${CMD:-?} error id=${ID:-} code=$1 reason=$2"
    exit "$1"
}
ok() { echo "tenant.sh $CMD ok id=$ID status=$1 seconds=$(elapsed)"; exit 0; }

# sa sqlcmd. Fails the caller on a SQL error (-b), prints nothing extra.
sql() { "$SQLCMD_BIN" -S "$SQL_SERVER" -U sa -C -No -b "$@"; }
# Scalar query: one trimmed value.
scalar() { sql -h -1 -W -Q "SET NOCOUNT ON; $1" 2>/dev/null | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//'; }

usage() {
    cat >&2 <<'EOF'
usage: tenant.sh add <id> | remove <id> | list
  id: ^[a-z0-9][a-z0-9-]{0,62}$ (also the tenant database name)
EOF
    exit 2
}

valid_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }

# The app database is whatever the NST is configured with.
APP_DB=$(grep -o 'DatabaseName" value="[^"]*"' "$CONFIG" 2>/dev/null | head -1 | sed 's/.*value="\(.*\)"/\1/')

require_ready() {
    [ -n "$APP_DB" ] || fail 5 "no-service-config"
    grep -q '<add key="Multitenant" value="true"' "$CONFIG" 2>/dev/null || fail 5 "not-multitenant"
    [ "$(scalar "IF DB_ID(N'$APP_DB') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM [$APP_DB].sys.extended_properties WHERE class = 0 AND name = N'bc_mt_ready'")" = "1" ] \
        || fail 5 "app-database-not-ready"
    local bak
    bak=$(scalar "DECLARE @t TABLE (a int, b int, c int); INSERT @t EXEC master.dbo.xp_fileexist N'$TEMPLATE_BAK'; SELECT TOP 1 a FROM @t")
    [ "$bak" = "1" ] || fail 5 "template-backup-missing"
}

# HTTP status of the tenant's OData Company page (000 when nothing answers).
probe() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -u "$BC_SERVER_USERNAME:$BC_SERVER_PASSWORD" "$ODATA_URL?tenant=$1" 2>/dev/null || echo 000
}

# State of the tenant's registration row: 0 active, 1 removed (the NST has been
# told to dismount it and deletes the row once it has), empty when there is no row.
row_state() { scalar "SELECT TOP 1 tenantconfigurationstate FROM [$APP_DB].dbo.[\$ndo\$tenants] WHERE tenantid = N'$(echo "$1" | tr a-z A-Z)'"; }
row_exists() { [ -n "$(row_state "$1")" ]; }

db_state() { scalar "SELECT ISNULL((SELECT state_desc FROM sys.databases WHERE name = N'$1'), N'')"; }

xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; s="${s//\'/&apos;}"
    printf '%s' "$s"
}

# The tenant settings document exactly as NST's own serializer writes it (see
# MULTITENANT.md); the plain-text password works because the StartupHook makes
# the protected-password round trip a pass-through.
tenant_xml() {
    local id="$1" pw user srv
    pw=$(xml_escape "$BC_DB_PASSWORD"); user=$(xml_escape "$BC_DB_USER"); srv=$(xml_escape "$SQL_SERVER")
    printf '%s' '<?xml version="1.0" encoding="utf-8"?><NavTenantSettings xmlns:i="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://www.microsoft.com/Dynamics/NAV/51"><AadTenantId i:nil="true" /><AllowAppDatabaseWrite>false</AllowAppDatabaseWrite><ApplicationInsightsKey i:nil="true" /><AzureKeyVaultSettings xmlns:d2p1="http://schemas.datacontract.org/2004/07/Microsoft.Dynamics.Nav.Types" i:nil="true" /><BapEnvironmentId i:nil="true" /><BindingManifest i:nil="true" /><BindingManifestEntries i:nil="true" /><DatabaseConnectionCredentialType>UsernamePassword</DatabaseConnectionCredentialType>'
    printf '<DatabaseName>%s</DatabaseName><DatabaseServer>%s</DatabaseServer><DatabaseUserName>%s</DatabaseUserName>' "$id" "$srv" "$user"
    printf '%s' '<DefaultCompany></DefaultCompany><DefaultTimeZoneSerialized i:nil="true" />'
    printf '<DisplayName>%s</DisplayName>' "$id"
    printf '%s' '<EncryptionProvider>LocalKeyFile</EncryptionProvider><EnvironmentSettings xmlns:d2p1="http://schemas.datacontract.org/2004/07/System.Collections.ObjectModel"><d2p1:m_dictionary xmlns:d3p1="http://schemas.microsoft.com/2003/10/Serialization/Arrays" /></EnvironmentSettings><EnvironmentType>Sandbox</EnvironmentType><ExchangeAuthenticationMetadataLocation i:nil="true" />'
    printf '<Id>%s</Id>' "$id"
    printf '<NasServicesEnabled>false</NasServicesEnabled><ProtectedDatabasePassword><Value>%s</Value></ProtectedDatabasePassword>' "$pw"
    printf '%s' '<RunNasWithAdminRights>false</RunNasWithAdminRights><TenantDatabaseId i:nil="true" /><UrlName i:nil="true" /><alternateId xmlns:d2p1="http://schemas.microsoft.com/2003/10/Serialization/Arrays" /><validAudiences xmlns:d2p1="http://schemas.microsoft.com/2003/10/Serialization/Arrays" /></NavTenantSettings>'
}

# Idempotent registration (the password only ever travels on stdin).
register_row() {
    local id="$1" hex
    hex=$( { printf '\xef\xbb\xbf'; tenant_xml "$id"; } | od -An -v -tx1 | tr -d ' \n')
    printf "%s\n" "IF NOT EXISTS (SELECT 1 FROM [$APP_DB].dbo.[\$ndo\$tenants] WHERE tenantid = N'$(echo "$id" | tr a-z A-Z)')
    INSERT INTO [$APP_DB].dbo.[\$ndo\$tenants] (tenantid, tenantconfigurationstate, tenantsettings, version)
    VALUES (N'$(echo "$id" | tr a-z A-Z)', 0, 0x$hex, 1000);" | sql -i /dev/stdin >/dev/null
}

# Installed-app state of a tenant lives in the APP database: [Installed Application]
# has one row per (tenant, app). The template carries the stock apps as tenant
# 'default'; a new tenant gets its own copy of those rows (this is what
# Install-NAVApp -Tenant would write), otherwise every dependency check says the
# stock apps are "not installed" for it.
clone_installed_apps() {
    local id="$1"
    sql -Q "
    IF NOT EXISTS (SELECT 1 FROM [$APP_DB].dbo.[Installed Application] WHERE [Tenant ID] = N'$id')
        INSERT INTO [$APP_DB].dbo.[Installed Application]
            ([Runtime Package ID], [Tenant ID], [Package ID], [\$systemId], [\$systemCreatedAt], [\$systemCreatedBy], [\$systemModifiedAt], [\$systemModifiedBy])
        SELECT [Runtime Package ID], N'$id', [Package ID], NEWID(), [\$systemCreatedAt], [\$systemCreatedBy], [\$systemModifiedAt], [\$systemModifiedBy]
        FROM [$APP_DB].dbo.[Installed Application] WHERE [Tenant ID] = N'default'" >/dev/null
}

# Everything a tenant left in the app database: its installed-app rows and the
# packages it published itself through the dev endpoint (Published As = Dev, keyed
# by tenant), with their metadata. Global apps (blank tenant) are never touched.
purge_tenant_apps() {
    local id="$1"
    sql -Q "
    SET NOCOUNT ON;
    DECLARE @r TABLE (id uniqueidentifier PRIMARY KEY);
    INSERT @r SELECT [Runtime Package ID] FROM [$APP_DB].dbo.[Published Application] WHERE [Tenant ID] = N'$id';
    DELETE FROM [$APP_DB].dbo.[Installed Application] WHERE [Tenant ID] = N'$id' OR [Runtime Package ID] IN (SELECT id FROM @r);
    DELETE FROM [$APP_DB].dbo.[Application Object Metadata] WHERE [Runtime Package ID] IN (SELECT id FROM @r);
    DELETE FROM [$APP_DB].dbo.[Application Dependency] WHERE [Runtime Package ID] IN (SELECT id FROM @r);
    DELETE FROM [$APP_DB].dbo.[Application Resource] WHERE [Runtime Package ID] IN (SELECT id FROM @r);
    DELETE FROM [$APP_DB].dbo.[Report Layout Definition] WHERE [Runtime Package ID] IN (SELECT id FROM @r);
    DELETE FROM [$APP_DB].dbo.[Inplace Installed Application] WHERE [Runtime Package ID] IN (SELECT id FROM @r);
    DELETE FROM [$APP_DB].dbo.[\$ndo\$inplacepublishingstate] WHERE [Runtime Package ID] IN (SELECT id FROM @r);
    DELETE FROM [$APP_DB].dbo.[Published Application] WHERE [Tenant ID] = N'$id';
    DELETE FROM [$APP_DB].dbo.[NAV App Tenant App] WHERE [Tenant ID] = N'$id';
    DELETE FROM [$APP_DB].dbo.[NAV App Publish Reference] WHERE [Tenant ID] = N'$id';
    DELETE FROM [$APP_DB].dbo.[NAV App] WHERE [Tenant ID] = N'$id'" >/dev/null
}

restore_db() {
    local id="$1" data_name log_name list
    list=$(sql -h -1 -s $'\t' -W -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = N'$TEMPLATE_BAK'" 2>/dev/null) || return 1
    data_name=$(printf '%s\n' "$list" | awk -F'\t' '$3 == "D" { print $1; exit }')
    log_name=$(printf '%s\n' "$list" | awk -F'\t' '$3 == "L" { print $1; exit }')
    [ -n "$data_name" ] && [ -n "$log_name" ] || return 1
    local q="'"
    sql -Q "RESTORE DATABASE [$id] FROM DISK = N'$TEMPLATE_BAK' WITH
        MOVE N'${data_name//$q/$q$q}' TO N'$DATA_DIR/$id.mdf',
        MOVE N'${log_name//$q/$q$q}' TO N'$DATA_DIR/${id}_log.ldf'" >/dev/null
}

cmd_add() {
    valid_id "$ID" || fail 2 "invalid-id"
    case "$ID" in
        "$(echo "$APP_DB" | tr A-Z a-z)"|"$(echo "$TEMPLATE_DB" | tr A-Z a-z)"|master|model|msdb|tempdb) fail 2 "reserved-id" ;;
    esac
    require_ready

    # A row still in state 1 is a previous removal the NST has not finished with;
    # it deletes the row when it is. Wait for that rather than racing it.
    local wait_deadline=$(( $(date +%s) + ADD_TIMEOUT ))
    while [ "$(row_state "$ID")" = "1" ]; do
        [ "$(date +%s)" -ge "$wait_deadline" ] && fail 3 "previous-removal-not-finished"
        sleep 2
    done

    # Already serving: nothing to do.
    if [ "$(row_state "$ID")" = "0" ] && [ "$(probe "$ID")" = "200" ]; then ok already-mounted; fi

    local state
    state=$(db_state "$ID")
    if [ -n "$state" ] && [ "$state" != "ONLINE" ]; then
        log "database $ID is $state, recreating"
        sql -Q "DROP DATABASE [$ID]" >/dev/null 2>&1 || sql -Q "ALTER DATABASE [$ID] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$ID]" >/dev/null || fail 4 "drop-failed"
        state=""
    fi
    if [ -z "$state" ]; then
        log "restoring $ID from the template"
        restore_db "$ID" || fail 4 "restore-failed"
    fi

    log "registering $ID"
    clone_installed_apps "$ID" || fail 4 "install-state-failed"
    register_row "$ID" || fail 4 "register-failed"

    local deadline=$(( $(date +%s) + ADD_TIMEOUT )) reinserts=0 code
    while :; do
        code=$(probe "$ID")
        if [ "$code" = "200" ]; then ok mounted; fi
        if ! row_exists "$ID"; then
            # The NST drops a tenant whose mount failed. One retry covers a mount
            # that raced the restore; a second drop is a real failure.
            if [ "$reinserts" -ge 1 ]; then fail 6 "mount-dropped-twice"; fi
            reinserts=$((reinserts + 1))
            log "the NST dropped the tenant, registering it once more"
            register_row "$ID" || fail 4 "register-failed"
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then fail 3 "mount-timeout-${ADD_TIMEOUT}s-last-http-$code"; fi
        sleep 2
    done
}

cmd_remove() {
    valid_id "$ID" || fail 2 "invalid-id"
    case "$ID" in
        "$(echo "$APP_DB" | tr A-Z a-z)"|"$(echo "$TEMPLATE_DB" | tr A-Z a-z)"|master|model|msdb|tempdb) fail 2 "reserved-id" ;;
    esac
    [ -n "$APP_DB" ] || fail 5 "no-service-config"
    local had=absent
    if [ -n "$(scalar "IF DB_ID(N'$APP_DB') IS NULL SELECT N'' ELSE SELECT N'x'")" ] && row_exists "$ID"; then
        had=removed
        # Removal is two-phase, like Dismount-NAVTenant: mark the row removed (state 1),
        # the NST dismounts the tenant and then deletes the row itself.
        sql -Q "UPDATE [$APP_DB].dbo.[\$ndo\$tenants] SET tenantconfigurationstate = 1 WHERE tenantid = N'$(echo "$ID" | tr a-z A-Z)'" >/dev/null || fail 4 "unregister-failed"
        local deadline=$(( $(date +%s) + REMOVE_TIMEOUT ))
        while { row_exists "$ID" || [ "$(probe "$ID")" = "200" ]; } && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
        if row_exists "$ID"; then log "the NST has not acknowledged the removal after ${REMOVE_TIMEOUT}s, dropping the database anyway"; fi
    fi
    if [ -n "$(scalar "IF DB_ID(N'$APP_DB') IS NULL SELECT N'' ELSE SELECT N'x'")" ]; then
        purge_tenant_apps "$ID" || fail 4 "purge-failed"
    fi
    if [ -n "$(db_state "$ID")" ]; then
        had=removed
        sql -Q "ALTER DATABASE [$ID] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$ID]" >/dev/null || fail 4 "drop-failed"
    fi
    ok "$had"
}

cmd_list() {
    [ -n "$APP_DB" ] || fail 5 "no-service-config"
    local rows id db st
    rows=$(sql -h -1 -s $'\t' -W -Q "SET NOCOUNT ON; SELECT LOWER(tenantid),
        CASE WHEN CHARINDEX(N'<DatabaseName>', s) > 0
             THEN SUBSTRING(s, CHARINDEX(N'<DatabaseName>', s) + 14, CHARINDEX(N'</DatabaseName>', s) - CHARINDEX(N'<DatabaseName>', s) - 14)
             ELSE N'' END
        FROM (SELECT tenantid, CONVERT(nvarchar(max), CONVERT(varchar(max), CONVERT(varbinary(max), tenantsettings))) AS s FROM [$APP_DB].dbo.[\$ndo\$tenants]) x
        ORDER BY tenantid" 2>/dev/null) || fail 4 "sql-error"
    while IFS=$'\t' read -r id db; do
        [ -n "$id" ] || continue
        if [ "$(db_state "$db")" != "ONLINE" ]; then st=offline
        elif [ "$(probe "$id")" = "200" ]; then st=mounted
        else st=mounting; fi
        printf '%s\t%s\t%s\n' "$id" "$db" "$st"
    done <<< "$rows"
}

case "$CMD" in
    add) [ $# -eq 2 ] || usage; cmd_add ;;
    remove) [ $# -eq 2 ] || usage; cmd_remove ;;
    list) [ $# -eq 1 ] || usage; cmd_list ;;
    *) usage ;;
esac
