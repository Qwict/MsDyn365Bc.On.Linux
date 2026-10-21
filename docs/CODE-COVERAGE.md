# Code coverage

How `run-tests.sh` and the Test Runner Extension record code coverage, why it is
built this way, and what the output means. Read this before changing anything under
`extensions/TestRunnerExtension/src/Coverage*` or the coverage part of `run-tests.sh`.

## What a correct coverage report is

Every mature coverage tool agrees on three rules (sources at the end):

1. **The denominator is the code under test, not the code that happened to run.**
   Code that no test loaded counts as 0%, not as absent. JaCoCo reports every class of
   the configured class files; coverage.py's `source=` scans for files that were never
   imported; Istanbul and c8 need `all`/`--all`; lcov builds a zero baseline with
   `geninfo --initial`; Go reports untested packages as `0.0%` since 1.22. A percentage
   over loaded code only is inflated, and the more code no test touches, the more so.
2. **Measure the project's own production code.** Tests, test libraries and
   dependencies are excluded by default (cargo-llvm-cov, coverlet, nyc). Dependencies
   that a test happens to run are incidental coverage, not verification.
3. **Publish an interchange format.** Cobertura XML is the format Azure DevOps,
   GitLab, GitHub and ReportGenerator all read; LCOV is the other common one. A
   correct file lists every executable line in scope (`hits="0"` included), names
   files relative to the repository root, and claims branch data only when it has
   some.

Line coverage is the baseline every tool supports; function coverage is common;
branch coverage is the usual next step. Coverage finds untested code; it says little
about how good the tests are (Google, Fowler), so gate on new code rather than on an
absolute number.

## What Business Central offers

Verified on BC 29.0 (build 29.0.54011.56707) with a probe app, 2026-10-21:

| Platform behaviour | Consequence |
|---|---|
| `CodeCoverageLog(true, MultiSession)` starts recording and resets all hits; `false` stops it. With `MultiSession = true` hits from other sessions are recorded too. | Start once per run; a restart loses hits. |
| The `Code Coverage` table (2000000049) only has rows for objects the session loaded — until `CodeCoverageInclude(AllObj)` registers objects up front. Included objects get all their lines at 0 hits; includes survive a later `CodeCoverageLog(true)`. Include is a no-op while the log is off. | Include the code under test after starting the log: untouched objects then count as 0%. |
| A second `CodeCoverageInclude` call in the same log undoes the first: with one call per app and two apps in scope, nothing stayed registered. | Include every app under test in one call, with an `App Package ID` filter that lists all their packages. |
| Include does **not** load table, page or report *extensions*: they get rows only once their code runs, under their own type and ID. | Extension objects no test ran cannot be measured; report them as unmeasured instead of hiding them. |
| Rows are only visible after `CodeCoverageRefresh()`. | Refresh before every read. |
| `AllObj."App Package ID"` equals the installed app's `Package ID` (`NAV App Installed App`). `App Runtime Package ID` differs for some apps. | Scope objects to an app through `App Package ID`. |
| `Format("Object Type")` is localized ("Tabel" in Dutch); `Format(x, 0, 9)` is the ordinal. Ordinals: 1 Table, 3 Report, 5 Codeunit, 6 XMLport, 8 Page, 9 Query, 14 PageExtension, 15 TableExtension, 22 ReportExtension. | Write object types from the ordinal, as AL keywords. |
| `Line Type`: 0 Object, 1 Trigger/Function, 2 Empty, 3 Code. Only Code rows carry hits. A Trigger/Function row's `Line` is the signature; its `Method Id` is -1 until the method runs. | Line coverage counts Code rows; function coverage comes from `Method Id`. |
| `Code Coverage Status` PartiallyCovered marks a single line whose branches did not all run (`if X then exit(a) else exit(b);` with one taken). There are no branch counts. | Report it as a partially covered line, never as branch coverage. |
| `Line No.` is the line in the .al file for the first object in a file; a later object in the same file counts from the line after the previous object's closing brace. `Line` is the source text only when the app exposes it (`includeSourceInSymbolFile`). | Map to file lines when the source is known. |
| Reads filtered on `Object ID` use an index (11,000 rows in 0.12 s); a read filtered only on `Line Type` scans everything (Base Application: 1.1 M rows, 20 s warm, 134 s cold). | Read only the IDs in scope. |

Microsoft's own Test Runner exports only covered lines and never includes untouched
objects, so its percentages have the first problem above.

## Design

### Scope

A run measures the **apps under test**: `startCoverageForApps` takes their app IDs, a
comma separated list of at most 2048 characters (longer returns `false`). Their objects
are found in `AllObj` through each app's package ID and included after the log starts.
An ID that is not a GUID, not installed, or the extension's own is not measured and is
listed in the report (`M,ignored`). `startCoverage` (no IDs) keeps the old behaviour,
the legacy scope: every loaded object in the partner ID ranges, nothing included up
front, hits of the test session only (`Multi Session` false; true in apps mode), so an
older `run-tests.sh` still works.

`run-tests.sh --coverage-app <id>` names the apps (repeatable). Without it, the apps
under test default to the test app's dependencies, leaving out Microsoft's apps and
apps whose name contains "Test" (test libraries). The script prints the scope and drops
values that are not a GUID with a warning.

An OData action that fails inside the extension still answers HTTP 200 with
`{"value":false}`, so `run-tests.sh` reads the body. `startCoverageForApps` returning
`false` (or answering 400/404 on an older extension) falls back to the legacy
`startCoverage`; that returning `false` turns coverage off with a warning; `stopCoverage`
returning `false` warns and reads what was recorded anyway. A `report` field that is
present but empty means the extension wrote nothing because coverage never started in
the test session: the script says so and writes no files. An incomplete report prints
`WARN: coverage report incomplete` and the summary says so too.

### Recording

The `Coverage Recorder` (SingleInstance, in the session that runs the tests):

1. before the first test codeunit of a run: starts the log (multi-session), includes
   the scope's objects, and writes the inventory — every line in scope at 0 hits;
2. writes the run so far between test codeunits under the checkpoint policy below, and
   after the last test codeunit, marking the report complete;
3. a session that replaces a dead one continues from the stored hits.

Every write reads only the scope's object IDs, so its cost follows the size of the
apps under test, not of the database.

**Checkpoint policy.** After a test codeunit that is not the last, the recorder writes
when the time since the last write is at least the larger of 30 s and 50 times the
duration of that write. That bounds the checkpoint overhead to about 2% of the run
whatever the size of the apps, and a session that dies loses at most the hits since the
last checkpoint. A fixed interval would be too slow for small apps and too heavy for big
ones. Because the inventory is written first, a run
that never reaches its final write still has the right denominator; the report says it
is incomplete.

### Stored report

One UTF-8 text blob in `Coverage Setup`, one record per line, comma separated, with a
leading record type:

```
M,<key>,<value>                          run metadata, see below
A,<app id>,<name>,<publisher>,<version>  an app under test
O,<type>,<id>,<app id>,<measured 0|1>     an object in scope; 0 = BC has no lines for it
L,<type>,<id>,<line>,<hits>,<partial 0|1> an executable (Code) line
F,<type>,<id>,<line>,<executed 0|1>,<signature>  a trigger or procedure
```

Metadata keys: `version` (2), `generation` (the run), `complete` (1 after the last test
codeunit), `mode` (`apps` or `legacy`), `started`, `written`, `ignored` (the app ids
asked for but not measured, semicolon separated; only present when there are any) and
the recorder's diagnostics, which describe the writes **before** this one, since a
write's own cost is only known after it is stored:

| Key | Meaning |
|---|---|
| `writes` | writes completed in the run so far, the inventory included |
| `write_ms` | total time of those writes, ms |
| `last_write_ms` | time of the most recent one, ms |
| `include_ms` | time of the `CodeCoverageInclude` step at the start, ms |
| `inventory_lines` | Code lines of the inventory write (the first of a session) |

In the legacy scope the `O` records only list objects that had lines, and their app id
is empty.

`<type>` is the AL keyword (`Codeunit`, `TableExtension`, ...). The signature is the
last field and may contain commas; it is quoted CSV-style when it does. It is empty when
BC gave no declaration: an app with `ShowMyCode` off puts a notice in place of its
source, and the extension drops that text (a declaration starts with `procedure` or
`trigger`, after an optional `local`, `internal` or `protected`). The
`coverageReports` API returns it as `report`, with `complete` and the counts; `csv`
keeps the old format (`object_type,object_id,line_no,hits` per Code line) for older
callers.

### Output (`run-tests.sh`)

| Option | Output |
|---|---|
| `--coverage-output <path>` | CSV `object_type,object_id,line_no,hits` — the control plane's input, unchanged |
| `--coverage-cobertura <path>` | Cobertura XML: a package per app, a class per object, `<methods>` from triggers and procedures, every Code line with its hits |
| `--coverage-lcov <path>` | LCOV tracefile: `SF`, `FN`/`FNDA`, `DA`, `LF`/`LH` per object |
| `--coverage-source <dir>` | Maps objects to their .al files under `<dir>` (skipping `.alpackages`, `.git`, `.snapshots`, `node_modules`, `.vscode`), so the Cobertura and LCOV files name file paths and file line numbers |
| `--coverage-root <dir>` | The directory those paths are relative to. Default: the git toplevel of `--coverage-source` when it is inside a git work tree, else `--coverage-source` |
| `--coverage-app <id>` | An app under test (repeatable) |

Without `--coverage-source` a class is named after its object (`Codeunit 50100`). With
it, `filename` and `SF` are POSIX paths relative to the root and Cobertura's single
`<source>` is `.`, so Azure DevOps and GitLab resolve them against the repository root.

Method names: the procedure or trigger name from the signature; when BC gave none, the
name at the mapped line in the .al file; else `L<line>`. A name is unique within its
object: a repeat (a table's field triggers are all `OnValidate`) gets `@<line>`. LCOV
`FN` names have commas replaced by `_`.

Unmeasured objects (BC has no lines for them) appear only in the summary, with the apps
that were asked for but not measured; they are not in the Cobertura or LCOV files, which
list only objects with lines.

Minimum Test Runner Extension: 4.0 for scoped coverage and for Cobertura/LCOV with
functions; 3.4 for the legacy report (lines only, every loaded partner object).

## Performance

Measured on BC 29 (dev, 2026-10-21), the same container running each suite without and
with coverage in alternating runs:

| Suite | Code lines in scope | Without | With | Overhead |
|---|---|---|---|---|
| Medium app, 143 tests | 22,626 | 115.7 s | 121.5 s | +5.0% (median +5.9%) |
| Large app, 4,899 tests | 564,472 | 1,330 s | 1,405 s | +5.6% |
| Small app, 122 tests | 694 | 8.2 s | 9.8 s | +1.5 s, fixed cost |

Where it goes, on the medium app: about 4% is the platform's own line tracking while
the tests run; the rest is the inventory and final writes (~1.3 s each), reading the
report (~1.2 s) and converting it (0.06 s). A write reads ~15,000-18,000 lines a second
when warm, so the fixed cost grows with the size of the apps under test, not with the
number of tests; checkpoints are bounded to ~2% of the run. The first read of a large
scope in a freshly started service tier is slower (the large app: 163 s instead of 29 s once).
A Cobertura file is ~150 bytes per line (the large app: 81 MB).

## Known limits

- Line coverage and function coverage only; BC has no branch data.
- Table, page and report extensions no test ran are listed as unmeasured objects but
  add no lines to the total.
- The line total can grow during a run: extension objects that Include cannot register
  get their lines when their code first runs, so a checkpoint or a killed run can show a
  smaller total than a complete one (observed on the medium app: inventory 20,243 lines, complete
  report 22,626).
- Hits since the last checkpoint are lost if the test session dies; the report is then
  marked incomplete.

## Upgrade

Extension 3.x stored coverage in the `Coverage Line` table and in a blob of
`Coverage Setup`. Both are obsolete and emptied by the `Coverage Upgrade` codeunit on
upgrade; it is idempotent, as upgrade tags need a module dependency this extension does
not have.

## Integration note

This branch is based on 68a2e68 (the production line). `feat/multitenant` adds
`--tenant` to `run-tests.sh` and `publish-app.sh` and will need merging with the
coverage changes in `run-tests.sh`.

## Sources

- JaCoCo: https://www.jacoco.org/jacoco/trunk/doc/counters.html, https://www.jacoco.org/jacoco/trunk/doc/faq.html
- coverage.py: https://coverage.readthedocs.io/en/latest/source.html
- nyc / c8: https://github.com/istanbuljs/nyc, https://github.com/bcoe/c8
- lcov `geninfo --initial` and tracefile format: https://manpages.debian.org/testing/lcov/geninfo.1.en.html
- Go 1.22: https://go.dev/doc/go1.22
- cargo-llvm-cov: https://github.com/taiki-e/cargo-llvm-cov
- Cobertura DTD: https://raw.githubusercontent.com/cobertura/web/master/htdocs/xml/coverage-04.dtd
- Azure DevOps: https://learn.microsoft.com/en-us/azure/devops/pipelines/test/review-code-coverage-results
- GitLab: https://docs.gitlab.com/ci/testing/code_coverage/coverage_visualization/
- Google, Code Coverage Best Practices: https://testing.googleblog.com/2020/08/code-coverage-best-practices.html
- Fowler, TestCoverage: https://martinfowler.com/bliki/TestCoverage.html
- BC: `Code Coverage` table, `CodeCoverageInclude`, `AllObj` on learn.microsoft.com; Microsoft's Test Runner in github.com/microsoft/BCApps (`src/Tools/Test Framework/Test Runner/src/CodeCoverage`)
