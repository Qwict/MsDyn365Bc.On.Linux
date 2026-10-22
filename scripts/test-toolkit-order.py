#!/usr/bin/env python3
"""Print the test toolkit .app paths of an artifact tree, dependencies first.

Usage: test-toolkit-order.py <artifacts dir>

The toolkit is what a fresh tenant needs before an ordinary test app compiles:
the core test framework the boot wipes from SQL (BC ships it "published as
Global, not installed"), plus the test libraries that are not in the sandbox
database at all. One list for every caller: the entrypoint's default flow
publishes it into a single-tenant instance, scripts/tenant.sh into every new
tenant of a multitenant one, and the two must not drift apart.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bcapp import load_artifact_apps  # noqa: E402

# This list rarely changes; last change was ~5 years ago.
NAMES = {
    "Test Runner", "Library Assert", "Library Variable Storage",
    "Permissions Mock", "Any",
    "System Application Test Library", "Business Foundation Test Libraries",
    "Tests-TestLibraries",
}


def main(artifacts):
    apps = load_artifact_apps(artifacts)
    wanted = {aid for aid, info in apps.items() if info.get("name") in NAMES}
    visited, ordered = set(), []

    def visit(aid):
        if aid in visited:
            return
        visited.add(aid)
        info = apps.get(aid)
        if info is None:
            return
        for dep in info.get("dependencies", []):
            visit(dep["id"])
        if aid in wanted:
            ordered.append(info["path"])

    for aid in sorted(wanted):
        visit(aid)
    for path in ordered:
        print(path)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[2])
    main(sys.argv[1])
