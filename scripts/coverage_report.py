#!/usr/bin/env python3
"""coverage_report.py - turn the Test Runner Extension's coverage report into
the formats other tools read (legacy CSV, Cobertura XML, LCOV) and a summary.

The extension stores one text report per run (see docs/CODE-COVERAGE.md,
"Stored report"). This module parses it into a small model, optionally maps each
object to its .al file so the output names repository paths and file line
numbers, and writes the formats. It is stdlib only so run-tests.sh can call it
inside any container without installing anything.

CLI (used by run-tests.sh):

    coverage_report.py --report FILE | --legacy-csv FILE
        [--complete true|false] [--source DIR] [--root DIR]
        [--csv-out P] [--cobertura P] [--lcov P]

Exit code is 0 even when the report is odd: coverage is best effort and the
caller decides what to do. Warnings go to stderr, the summary to stdout.
"""

from __future__ import annotations

import argparse
import csv
import bisect
import io
import os
import re
import sys
import time
from xml.sax.saxutils import quoteattr

# Object type ordinals as BC reports them (docs/CODE-COVERAGE.md). Only needed
# when a legacy CSV carries numbers instead of AL keywords.
ORDINAL_TYPES = {
    "1": "Table", "3": "Report", "5": "Codeunit", "6": "XMLport", "8": "Page",
    "9": "Query", "14": "PageExtension", "15": "TableExtension",
    "22": "ReportExtension",
}

LEGACY_PACKAGE = "(all partner objects)"
UNKNOWN_PACKAGE = "(unknown app)"


class Report:
    """The parsed coverage of one run."""

    def __init__(self):
        self.meta = {}        # key -> value
        self.apps = {}        # app id -> {"name", "publisher", "version"}
        self.objects = {}     # (type, id) -> {"app": app id, "measured": bool}
        self.lines = {}       # (type, id) -> {line: (hits, partial)}
        self.functions = {}   # (type, id) -> [(line, executed, signature)]
        self.warnings = []
        self.skipped = 0      # malformed rows
        self.legacy = False   # legacy CSV, or a v2 report of the legacy scope: no app names

    def warn(self, msg):
        self.warnings.append(msg)

    def complete(self):
        """True/False from the report's own flag, None when it carries none."""
        v = self.meta.get("complete")
        if v is None:
            return None
        return str(v).strip().lower() in ("1", "true", "yes")

    def ensure_object(self, key):
        if key not in self.objects:
            self.objects[key] = {"app": "", "measured": True}
        return self.objects[key]


def _split_csv(text):
    """Split one CSV row, honouring quotes (doubled quotes escape)."""
    return next(csv.reader([text]))


def _unquote(s):
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1].replace('""', '"')
    return s


def _split_fields(rest, n):
    """Split off n leading plain fields; the remainder is the last field, which
    may be CSV-quoted because a signature can hold commas. None when too short."""
    parts = rest.split(",", n)
    if len(parts) < n + 1:
        return None
    return parts[:n] + [_unquote(parts[n])]


def parse_report(text):
    """Parse the v2 text report. Unknown record types are ignored so a newer
    extension can add records without breaking this reader."""
    r = Report()
    # Split on "\n" only: str.splitlines also breaks on \x0b, \x1c and friends, which
    # can sit inside a signature BC stored, and would cut that record in two.
    for raw in text.split("\n"):
        line = raw[:-1] if raw.endswith("\r") else raw
        if not line.strip():
            continue
        kind, _, rest = line.partition(",")
        try:
            if kind == "M":
                k, _, v = rest.partition(",")
                if not k:
                    raise ValueError("empty key")
                r.meta[k] = v
            elif kind == "A":
                f = _split_csv(rest)
                if len(f) < 4:
                    raise ValueError("short A")
                r.apps[f[0].lower()] = {
                    "name": f[1], "publisher": f[2], "version": f[3]}
            elif kind == "O":
                f = rest.split(",")
                if len(f) != 4:
                    raise ValueError("bad O")
                key = (f[0], int(f[1]))
                r.objects[key] = {"app": f[2].lower(), "measured": f[3] == "1"}
            elif kind == "L":
                f = rest.split(",")
                if len(f) != 5:
                    raise ValueError("bad L")
                key = (f[0], int(f[1]))
                no, hits, partial = int(f[2]), int(f[3]), f[4] == "1"
                lines = r.lines.setdefault(key, {})
                if no in lines:
                    # Should not happen. Summing would double count a repeated
                    # write, so keep the larger count.
                    r.warn(f"duplicate line {key[0]} {key[1]}:{no}; keeping the highest hits")
                    old_hits, old_partial = lines[no]
                    hits, partial = max(hits, old_hits), partial or old_partial
                lines[no] = (hits, partial)
            elif kind == "F":
                f = _split_fields(rest, 4)
                if f is None:
                    raise ValueError("bad F")
                key = (f[0], int(f[1]))
                r.functions.setdefault(key, []).append(
                    (int(f[2]), f[3] == "1", f[4]))
            # any other record type: ignored on purpose
        except (ValueError, csv.Error):
            r.skipped += 1
    if r.skipped:
        r.warn(f"{r.skipped} malformed report line(s) skipped")
    # The legacy scope has no app list; its objects carry an empty app id.
    r.legacy = r.meta.get("mode") == "legacy"
    return r


def parse_legacy_csv(text):
    """Parse the old object_type,object_id,line_no,hits CSV (header optional)."""
    r = Report()
    r.legacy = True
    for i, row in enumerate(csv.reader(io.StringIO(text))):
        if not row:
            continue
        if i == 0 and row[0].strip().lower() == "object_type":
            continue
        try:
            if len(row) != 4:
                raise ValueError("bad row")
            typ = ORDINAL_TYPES.get(row[0].strip(), row[0].strip())
            key = (typ, int(row[1]))
            no, hits = int(row[2]), int(row[3])
        except ValueError:
            r.skipped += 1
            continue
        r.ensure_object(key)
        lines = r.lines.setdefault(key, {})
        if no in lines:
            r.warn(f"duplicate line {typ} {key[1]}:{no}; keeping the highest hits")
            hits = max(hits, lines[no][0])
        lines[no] = (hits, False)
    if r.skipped:
        r.warn(f"{r.skipped} malformed CSV row(s) skipped")
    return r


# --- Source mapping ---------------------------------------------------------

# Keywords that start an object. The first group has an id; the second does not.
_ID_KEYWORDS = {
    "codeunit": "Codeunit", "table": "Table", "page": "Page",
    "report": "Report", "xmlport": "XMLport", "query": "Query",
    "tableextension": "TableExtension", "pageextension": "PageExtension",
    "reportextension": "ReportExtension", "enum": "Enum",
    "enumextension": "EnumExtension", "permissionset": "PermissionSet",
    "permissionsetextension": "PermissionSetExtension",
    "pagecustomization": "PageCustomization",
}
_NOID_KEYWORDS = {"interface", "controladdin", "profile", "entitlement", "dotnet"}

_DECL = re.compile(
    r'(?<![\w."])(' + "|".join(sorted(_ID_KEYWORDS, key=len, reverse=True)) +
    r')\s+(\d+)\s+("[^"\n]*"|\w+)', re.IGNORECASE)
_QUOTED = re.compile(r'"[^"\n]*"')
_DECL_NOID = re.compile(
    r'(?<![\w."])(' + "|".join(sorted(_NOID_KEYWORDS)) + r')\s+("[^"\n]*"|\w+)',
    re.IGNORECASE)


def _blank_comments_and_strings(src):
    """Replace comments and 'string literals' with spaces, keeping newlines, so
    declarations and braces found afterwards are real code. Double-quoted
    identifiers are kept (they are names, not strings) but a comment marker
    inside one is not a comment."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == "//":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
        elif two == "/*":
            end = src.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append("".join(ch if ch == "\n" else " " for ch in src[i:end]))
            i = end
        elif c == "'":
            out.append(" ")
            i += 1
            while i < n and src[i] != "'" and src[i] != "\n":
                out.append(" ")
                i += 1
            if i < n and src[i] == "'":
                out.append(" ")
                i += 1
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"' and src[j] != "\n":
                j += 1
            if j < n and src[j] == '"':
                j += 1
            out.append(src[i:j])
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def find_objects(src):
    """Objects declared in one .al file: [(type, id or None, start_line,
    close_line)]. Only top-level declarations count; a keyword inside an object
    (RunObject = Page 50100 ...) is not a declaration."""
    code = _blank_comments_and_strings(src)
    decls = {}
    for m in _DECL.finditer(code):
        decls[m.start()] = (_ID_KEYWORDS[m.group(1).lower()], int(m.group(2)))
    for m in _DECL_NOID.finditer(code):
        decls.setdefault(m.start(), (m.group(1).lower(), None))
    decl_pos = sorted(decls)

    # Braces inside a quoted identifier ("Name {x}") are part of the name.
    shape = _QUOTED.sub(lambda m: " " * len(m.group(0)), code)
    newlines = [m.start() for m in re.finditer("\n", shape)]

    def line_of(pos):
        return bisect.bisect_left(newlines, pos) + 1

    result = []
    depth = 0
    current = None
    nxt = 0  # next undecided declaration in decl_pos

    def take_decls_before(pos):
        nonlocal nxt, current
        while nxt < len(decl_pos) and decl_pos[nxt] < pos:
            if depth == 0 and current is None:
                d = decls[decl_pos[nxt]]
                current = (d[0], d[1], line_of(decl_pos[nxt]))
            nxt += 1

    for m in re.finditer(r"[{}]", shape):
        take_decls_before(m.start())
        if m.group(0) == "{":
            depth += 1
        else:
            depth -= 1
            if depth == 0 and current is not None:
                result.append((current[0], current[1], current[2], line_of(m.start())))
                current = None
    take_decls_before(len(shape) + 1)
    if current is not None:  # unterminated file: close at the last line
        result.append((current[0], current[1], current[2], len(newlines) + 1))
    return result


class SourceMap(dict):
    """(type, id) -> (path relative to the root, line offset), plus a way to read
    the source line an object's function is declared on."""

    def __init__(self):
        super().__init__()
        self.paths = {}   # (type, id) -> absolute path
        self._text = {}   # absolute path -> [lines]

    def line_text(self, key, bc_line):
        """The file line BC line `bc_line` of the object maps to, or None."""
        path = self.paths.get(key)
        if path is None:
            return None
        if path not in self._text:
            try:
                with open(path, encoding="utf-8-sig", errors="replace") as f:
                    self._text[path] = f.read().split("\n")
            except OSError:
                self._text[path] = []
        idx = bc_line + self[key][1] - 1
        lines = self._text[path]
        return lines[idx].rstrip("\r") if 0 <= idx < len(lines) else None


# Directories that hold packages, VCS data or build output, never the app's own
# sources; walking them is slow and can hold copies of the same objects.
_SKIP_DIRS = {".alpackages", ".git", ".snapshots", "node_modules", ".vscode"}


def map_sources(source_dir, root=None):
    """Map (type, id) -> (relative POSIX path, line offset) for every object
    under source_dir. Paths are relative to `root` (default source_dir): the
    repository root, so tools that resolve them against the checkout find the
    files. File line = BC line + offset. The first object in a file has offset
    0; a later one is numbered by BC from the line after the previous object's
    closing brace, so its offset is that brace's line."""
    mapping = SourceMap()
    base = root or source_dir
    for walk_root, dirs, files in os.walk(source_dir):
        dirs[:] = sorted(d for d in dirs if d not in _SKIP_DIRS)
        for name in sorted(files):
            if not name.lower().endswith(".al"):
                continue
            path = os.path.join(walk_root, name)
            try:
                with open(path, encoding="utf-8-sig", errors="replace") as f:
                    src = f.read()
            except OSError as e:
                print(f"WARN: cannot read {path}: {e}", file=sys.stderr)
                continue
            rel = os.path.relpath(path, base).replace(os.sep, "/")
            offset = 0
            for typ, oid, _start, close in find_objects(src):
                if oid is not None:
                    key = (typ, oid)
                    if key in mapping:
                        print(f"WARN: {typ} {oid} is declared in both "
                              f"{mapping[key][0]} and {rel}; using the first",
                              file=sys.stderr)
                    else:
                        mapping[key] = (rel, offset)
                        mapping.paths[key] = os.path.abspath(path)
                offset = close
    return mapping


# --- Model helpers ----------------------------------------------------------

def _label(key):
    return f"{key[0]} {key[1]}"


def _loc(key, mapping):
    """(file name, offset) for an object; unmapped objects are named after
    themselves with no offset."""
    if mapping and key in mapping:
        return mapping[key]
    return _label(key), 0


_REAL_DECL = re.compile(r"^\s*((local|internal|protected)\s+)?(procedure|trigger)\b", re.I)
_NAME = re.compile(r'\b(?:procedure|trigger)\s+("[^"]+"|\w+)', re.I)


def is_declaration(signature):
    """Whether a function row's text is a declaration. BC puts its ShowMyCode
    redaction notice there for apps that hide their code."""
    return bool(_REAL_DECL.match(signature or ""))


def method_name(signature):
    """The procedure or trigger name out of a declaration, None when the text is
    not one."""
    if not is_declaration(signature):
        return None
    m = _NAME.search(signature)
    return m.group(1).strip('"') if m else None


def _app_of(r, key):
    return r.objects.get(key, {}).get("app", "")


def _object_order(r):
    """Objects that have lines, in a stable order: by app, then type and id."""
    keys = set(r.lines) | {k for k, o in r.objects.items() if o["measured"]}
    return sorted(keys, key=lambda k: (_app_of(r, k), k[0], k[1]))


def _app_name(r, app_id):
    if app_id in r.apps:
        return r.apps[app_id]["name"] or app_id
    return LEGACY_PACKAGE if r.legacy else UNKNOWN_PACKAGE


def _rate(covered, valid):
    return covered / valid if valid else 0.0


def _covered(lines):
    return sum(1 for h, _p in lines.values() if h > 0)


def _declaration_from_source(mapping, key, bc_line):
    """The declaration text at a function's line in the mapped .al file. BC's
    line is the declaration itself or an attribute line above it, so look a few
    lines down."""
    if not isinstance(mapping, SourceMap):
        return None
    for extra in range(3):
        text = mapping.line_text(key, bc_line + extra)
        if text is not None and is_declaration(text):
            return text.strip()
    return None


def _methods(r, key, mapping=None):
    """[(line, name, executed, [(line, hits)...], signature)] with each Code
    line assigned to the function whose signature line precedes it, by bisecting
    the sorted function lines, so an object with thousands of lines stays cheap.

    A name comes from the signature BC gave, else from the .al source when it is
    mapped, else it is "L<line>". Names are unique within an object (a table's
    field triggers are all OnValidate): a repeat gets "@<line>"."""
    funcs = sorted(r.functions.get(key, []), key=lambda f: f[0])
    if not funcs:
        return []
    starts = [f[0] for f in funcs]
    mine = [[] for _ in funcs]
    for n, (h, _p) in sorted(r.lines.get(key, {}).items()):
        idx = bisect.bisect_right(starts, n) - 1
        if idx >= 0:
            mine[idx].append((n, h))
    off = mapping[key][1] if mapping and key in mapping else 0
    out = []
    seen = set()
    for (ln, executed, sig), lines in zip(funcs, mine):
        if not is_declaration(sig):
            sig = _declaration_from_source(mapping, key, ln) or ""
        name = method_name(sig) or f"L{ln + off}"
        if name in seen:
            name = f"{name}@{ln + off}"
        seen.add(name)
        out.append((ln, name, executed, lines, sig))
    return out


def compute_methods(r, mapping=None):
    """_methods for every object, computed once for all writers."""
    return {key: _methods(r, key, mapping) for key in r.functions}


# --- Writers ----------------------------------------------------------------

def to_legacy_csv(r):
    """The CSV the control plane reads: header plus one row per Code line, CRLF
    line ends."""
    rows = ["object_type,object_id,line_no,hits"]
    for key in sorted(r.lines):
        for no in sorted(r.lines[key]):
            rows.append(f"{key[0]},{key[1]},{no},{r.lines[key][no][0]}")
    return "".join(row + "\r\n" for row in rows)


def _xml_text(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def to_cobertura(r, mapping=None, source_dir=None, timestamp_ms=None, methods=None):
    """Cobertura XML (coverage-04.dtd). Partial lines stay branch="false": BC
    gives no branch counts and inventing some would be a false claim. Filenames
    are relative to the one source "." so Azure DevOps and GitLab resolve them
    against the repository root; source_dir is accepted for old callers."""
    if methods is None:
        methods = compute_methods(r, mapping)
    if timestamp_ms is None:
        timestamp_ms = int(time.time() * 1000)
    by_app = {}
    for key in _object_order(r):
        by_app.setdefault(_app_of(r, key), []).append(key)

    total_valid = sum(len(v) for v in r.lines.values())
    total_cov = sum(_covered(v) for v in r.lines.values())
    q = quoteattr
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           f'<coverage line-rate="{_rate(total_cov, total_valid):.4f}" branch-rate="0" '
           f'lines-covered="{total_cov}" lines-valid="{total_valid}" '
           f'branches-covered="0" branches-valid="0" complexity="0" '
           f'version="coverage_report/1" timestamp="{timestamp_ms}">',
           "  <sources>",
           "    <source>.</source>",
           "  </sources>", "  <packages>"]
    for app_id, keys in by_app.items():
        pl = sum(len(r.lines.get(k, {})) for k in keys)
        pc = sum(_covered(r.lines.get(k, {})) for k in keys)
        out.append(f'    <package name={q(_app_name(r, app_id))} '
                   f'line-rate="{_rate(pc, pl):.4f}" branch-rate="0" complexity="0">')
        out.append("      <classes>")
        for key in keys:
            fname, off = _loc(key, mapping)
            lines = r.lines.get(key, {})
            cl, cc = len(lines), _covered(lines)
            out.append(f'        <class name={q(_label(key))} filename={q(fname)} '
                       f'line-rate="{_rate(cc, cl):.4f}" branch-rate="0" complexity="0">')
            out.append("          <methods>")
            for _ln, name, executed, mine, sig in methods.get(key, []):
                if mine:
                    mr = _rate(sum(1 for _n, h in mine if h > 0), len(mine))
                else:
                    mr = 1.0 if executed else 0.0
                out.append(f'            <method name={q(name)} signature={q(sig)} '
                           f'line-rate="{mr:.4f}" branch-rate="0" complexity="0">')
                out.append("              <lines>")
                for n, h in mine:
                    out.append(f'                <line number="{n + off}" hits="{h}" branch="false"/>')
                out.append("              </lines>")
                out.append("            </method>")
            out.append("          </methods>")
            out.append("          <lines>")
            for n in sorted(lines):
                out.append(f'            <line number="{n + off}" hits="{lines[n][0]}" branch="false"/>')
            out.append("          </lines>")
            out.append("        </class>")
        out.append("      </classes>")
        out.append("    </package>")
    out += ["  </packages>", "</coverage>", ""]
    return "\n".join(out)


def to_lcov(r, mapping=None, methods=None):
    """LCOV tracefile: one record per object. FN names carry no comma, which is
    the field separator."""
    if methods is None:
        methods = compute_methods(r, mapping)
    out = []
    for key in _object_order(r):
        fname, off = _loc(key, mapping)
        lines = r.lines.get(key, {})
        fns = methods.get(key, [])
        out += ["TN:", f"SF:{fname}"]
        for ln, name, _e, _m, _s in fns:
            out.append(f"FN:{ln + off},{name.replace(',', '_')}")
        for _ln, name, executed, _m, _s in fns:
            out.append(f"FNDA:{1 if executed else 0},{name.replace(',', '_')}")
        out += [f"FNF:{len(fns)}",
                f"FNH:{sum(1 for m in fns if m[2])}"]
        for n in sorted(lines):
            out.append(f"DA:{n + off},{lines[n][0]}")
        out += [f"LF:{len(lines)}", f"LH:{_covered(lines)}", "end_of_record"]
    return "\n".join(out) + ("\n" if out else "")


def _pct(c, v):
    return f"{100.0 * c / v:.1f}%" if v else "n/a"


_DIAGNOSTICS = [
    ("writes", "writes"), ("write_ms", "write ms (total)"),
    ("last_write_ms", "last write ms"), ("include_ms", "include ms"),
    ("inventory_lines", "inventory lines"),
]


def summary(r, complete=None):
    """Human summary. `complete` overrides the report's own flag."""
    if complete is None:
        complete = r.complete()
    by_app = {}
    for key in set(r.lines) | set(r.objects):
        by_app.setdefault(_app_of(r, key), []).append(key)
    for app_id in r.apps:
        by_app.setdefault(app_id, [])

    out = ["=== Code coverage ==="]
    if r.meta.get("mode"):
        out.append(f"Mode: {r.meta['mode']}")
    ignored = [x for x in _unquote(r.meta.get("ignored", "")).split(";") if x]
    if ignored:
        out.append("WARNING: not measured: " + ", ".join(ignored))
    if complete is False:
        out.append("WARNING: INCOMPLETE REPORT - the run ended before the final write; "
                   "hits since the last checkpoint are missing")
    tl = tc = tf = tfe = tm = 0
    unmeasured = []
    for app_id in sorted(by_app, key=lambda a: _app_name(r, a).lower()):
        keys = by_app[app_id]
        lv = sum(len(r.lines.get(k, {})) for k in keys)
        lc = sum(_covered(r.lines.get(k, {})) for k in keys)
        fns = [f for k in keys for f in r.functions.get(k, [])]
        fe = sum(1 for f in fns if f[1])
        meas = [k for k in keys if r.objects.get(k, {"measured": True})["measured"]]
        unm = [k for k in keys if not r.objects.get(k, {"measured": True})["measured"]]
        out.append(f"{_app_name(r, app_id)}: {_pct(lc, lv)} lines ({lc}/{lv}), "
                   f"{fe}/{len(fns)} functions, {len(meas)} objects measured, "
                   f"{len(unm)} unmeasured")
        tl, tc, tf, tfe, tm = tl + lv, tc + lc, tf + len(fns), tfe + fe, tm + len(meas)
        unmeasured += unm
    out.append(f"Total: {_pct(tc, tl)} lines ({tc}/{tl}), {tfe}/{tf} functions, "
               f"{tm} objects measured, {len(unmeasured)} unmeasured")
    if unmeasured:
        out.append("Unmeasured (BC has no lines for them; no test ran their code): " +
                   ", ".join(_label(k) for k in sorted(unmeasured)[:20]) +
                   (f" ... and {len(unmeasured) - 20} more" if len(unmeasured) > 20 else ""))
    out.append("Complete: " + {True: "yes", False: "NO", None: "unknown"}[complete])
    diag = [f"{label} {r.meta[k]}" for k, label in _DIAGNOSTICS if k in r.meta]
    if diag:
        out.append("Recorder: " + ", ".join(diag))
    return "\n".join(out)


# --- CLI --------------------------------------------------------------------

def _write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def main(argv=None):
    p = argparse.ArgumentParser(description="Write coverage formats from a coverage report.")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--report", help="v2 report text file")
    src.add_argument("--legacy-csv", help="legacy object_type,object_id,line_no,hits CSV")
    p.add_argument("--complete", choices=["true", "false"],
                   help="the API's complete flag (overrides the report's own)")
    p.add_argument("--source", help="directory with the .al sources")
    p.add_argument("--root", help="directory the reported file paths are relative to "
                   "(the repository root; default: --source)")
    p.add_argument("--csv-out")
    p.add_argument("--cobertura")
    p.add_argument("--lcov")
    a = p.parse_args(argv)

    path = a.report or a.legacy_csv
    with open(path, encoding="utf-8-sig", newline="") as f:
        text = f.read()
    r = parse_report(text) if a.report else parse_legacy_csv(text)
    for w in r.warnings:
        print(f"WARN: {w}", file=sys.stderr)

    mapping = None
    if a.source:
        mapping = map_sources(a.source, a.root)
        wanted = set(r.lines)
        missing = sorted(k for k in wanted if k not in mapping)
        print(f"Source mapping: {len(wanted) - len(missing)}/{len(wanted)} objects "
              f"found under {a.source}")
        if missing:
            print("  not found in sources (named after the object): " +
                  ", ".join(_label(k) for k in missing[:20]) +
                  (" ..." if len(missing) > 20 else ""))
    if a.csv_out:
        _write(a.csv_out, to_legacy_csv(r))
    methods = compute_methods(r, mapping) if (a.cobertura or a.lcov) else None
    if a.cobertura:
        _write(a.cobertura, to_cobertura(r, mapping, a.source, methods=methods))
    if a.lcov:
        _write(a.lcov, to_lcov(r, mapping, methods=methods))
    complete = None if a.complete is None else a.complete == "true"
    print(summary(r, complete))
    return 0


if __name__ == "__main__":
    sys.exit(main())
