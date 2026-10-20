# Multitenant mode

One bc-runner container can serve many isolated tenants. The NST runs with
`Multitenant=true` against a shared **application database** (`app`); every tenant
is a separate **tenant database** registered in `[app].dbo.[$ndo$tenants]`. The NST
polls that table and mounts or dismounts tenants without a restart.

Single-tenant behaviour is unchanged unless `BC_MULTITENANT=1`.

## Enabling it

| Variable | Default | Meaning |
|---|---|---|
| `BC_MULTITENANT` | unset | `1` (or `true`/`yes`) turns the mode on. |
| `BC_DATABASE` | `CRONUS` | In this mode `CRONUS` means "use `app`"; any other value is the app database name. |
| `BC_TENANT_TEMPLATE_DB` | `tenant_template` | Name of the template. Its backup `/var/opt/mssql/data/<name>.bak` (on the SQL container) is what tenants are restored from. |
| `BC_SQL_TMPFS_SIZE` | `4g` | Size of the SQL data tmpfs (RAM-backed). 4g is too small here: the app DB (~0.9 GB), the template backup and ~0.4 GB per tenant all live in it. Use 16g or more, or a volume. |
| `DOTNET_GCHeapCount` | `4` in this mode | Server-GC heap count (hex). The .NET default is one heap per core. |
| `BC_TENANT_ADD_TIMEOUT` | `180` | tenant.sh: seconds to wait for a mount. The first tenant after an NST start needs about 2 minutes, see Timings. |
| `BC_TENANT_REMOVE_TIMEOUT` | `60` | tenant.sh: seconds to wait for the NST to dismount. |

`BC_SKIP_APP_PUBLISH` is forced to `true`: the container publishes nothing at boot.
Extensions (the Test Runner Extension, test apps) are published per tenant through
the dev endpoint, see below.

## Boot sequence

1. The CRONUS backup is restored as the template and prepared exactly like the
   single-tenant database (licence, tuning, app clearing, `BCRUNNER` user, tenant
   property keyed to `default`).
2. Split, in plain SQL (the same 53 application tables Export-/Remove-NAVApplication
   move): backup the template (`COPY_ONLY`, compressed) -> restore it as `app` ->
   drop everything but the application tables, all views and sequences, and truncate
   `$ndo$taskscheduling`; drop those tables from the template; shrink both data files
   to what is used (a tenant file is 0.4 GB instead of 1 GB: it is RAM on a tmpfs);
   back the template up again and drop the template database. `$ndo$publicencryptionkey`
   stays in both (the NST reads it from the app DB).
3. An extended property `bc_mt_ready` on `app` marks the split complete. A restart
   with that marker and the template backup present skips steps 1-2; a boot that
   died half way is redone from scratch, which is safe because no tenant can exist
   before the marker.
4. NST starts with no tenants. `/tmp/bc-ready` is touched once the dev endpoint
   answers `GET :7049/BC/dev/metadata` (that works without a tenant).

Readiness and health: the compose healthcheck is `test -f /tmp/bc-ready` plus a
200 from `http://localhost:7049/BC/dev/metadata` in this mode (the usual OData
`Company` probe otherwise). Healthy means "NST up, ready for `tenant.sh add`"; a
tenant is ready when `tenant.sh add` returns 0.

## tenant.sh

```
docker compose exec -T bc /bc/scripts/tenant.sh add <id>
docker compose exec -T bc /bc/scripts/tenant.sh remove <id>
docker compose exec -T bc /bc/scripts/tenant.sh list
```

`<id>` matches `^[a-z0-9][a-z0-9-]{0,62}$` and is also the tenant database name
(`app`, the template name and the system databases are reserved).

* **add**: restore the template backup as database `<id>`; set the tenant property
  row's `tenantid` to `<id>` (without it the tenant has no numeric id and e.g.
  creating a company fails with "Tenant numeric id must be set"); copy the stock
  installed-app rows for the tenant in the app DB (`[Installed Application]` is
  keyed by tenant; without them every dependency check says the stock apps are not
  installed); insert the registration row; poll `ODataV4/Company?tenant=<id>` until
  it answers 200 (one re-registration if the NST drops the mount). Already
  mounted: exits 0 at once.
* **remove**: mark the row removed (`tenantconfigurationstate = 1`, what
  Dismount-NAVTenant does: the NST dismounts and deletes the row itself; deleting
  the row directly is not noticed), delete the tenant's rows and the packages it
  published itself from the app DB, `DROP DATABASE`. Nothing to remove: exits 0.
* **list**: TSV on stdout, `id<TAB>database<TAB>state`, state one of `mounted`,
  `mounting`, `offline`.

Progress goes to stderr. add/remove end with exactly one stdout line:

```
tenant.sh add ok id=t1 status=mounted seconds=14         # status: mounted | already-mounted
tenant.sh remove ok id=t1 status=removed seconds=15      # status: removed | absent
tenant.sh add error id=t1 code=3 reason=mount-timeout-180s-last-http-503
```

| Exit | Meaning |
|---|---|
| 0 | done (also when already in the requested state) |
| 2 | bad arguments / invalid or reserved id |
| 3 | timed out waiting for the NST |
| 4 | SQL error |
| 5 | not a ready multitenant instance (mode off, split not finished, template backup missing) |
| 6 | the NST dropped the mount twice; the tenant database is kept, run `remove` to clean up |

## Using a tenant

Everything that talks to the NST carries the tenant: `?tenant=<id>` on OData, API
and dev URLs. Without a tenant `GET /BC/dev/metadata` answers 200, OData and
`dev/packages` answer 401/400.

* `scripts/run-tests.sh --tenant <id> ...` adds `tenant=<id>` to every BC request
  (company discovery, test API, coverage, publish) and passes `--tenant` to
  `TestRunner.dll`. Give each concurrent run its own `--junit-output`.
* `TestRunner.dll --tenant <id>`: the client session names the tenant twice, as the
  `<tenant>\<password>` prefix of the client-services password and in
  `ConnectionRequest.TenantId`. Either alone is rejected.
* `bc_publish_app <app> <dev-url> <auth> <tenant>` (or `BC_TENANT`) publishes to one
  tenant. **Per-tenant package ID:** apps published through the dev endpoint belong
  to one tenant and the NST rejects the same package ID for a second tenant
  ("A duplicate package ID is detected"). `scripts/tenant-app.py <in> <out> <tenant>`
  writes a copy whose package ID (the GUID at offset 12 of the 40-byte NAVX header,
  referenced nowhere else) is derived from the original and the tenant;
  `bc_publish_app` does this itself. Any other publisher has to do the same.

The stock apps (System Application, Base Application, the test framework the
artifact ships) are global and shared; the Test Runner Extension and any test app
are per tenant and have to be published into every tenant that runs tests.

## Timings and memory (BC 28.1 BE sandbox, 40-core host)

| | |
|---|---|
| cold boot to healthy (incl. 48 s split) | 90 s |
| restart of an already split instance | 26 s |
| first `tenant.sh add` after an NST start (the NST loads the tenant's 97 apps) | ~120 s |
| further `tenant.sh add` | 6-16 s |
| `tenant.sh remove` | 15-20 s |
| NST RSS, no tenant / 5 tenants mounted and tested, 4 GC heaps | 0.45 GB / 2.7 GB |
| same with 40 GC heaps (the .NET default) | 0.45 GB / 7.7 GB |
| SQL data per tenant (tmpfs) | ~0.4 GB |

## Limits and notes

* All tenants share one NST process: one memory budget, one CPU pool, one SQL
  instance. A tenant that wedges the NST affects all of them.
* A restart of the NST remounts every tenant: the first one pays the ~2 minutes
  again, the rest follow within seconds.
* The template is built from the artifact's database; changing BC version or
  artifact needs a fresh SQL volume (as in single-tenant mode). To move tenants to
  another build, boot a second host, `tenant.sh add` there, then `remove` here.
* The SQL data directory is a tmpfs by default: everything is lost when the SQL
  container is recreated, and the container is re-split on the next boot.
* `tenant.sh remove` removes the tenant's published packages from the app DB; the
  NST's compiled-assembly cache on disk is not pruned.
