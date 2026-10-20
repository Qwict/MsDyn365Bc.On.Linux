#!/usr/bin/env python3
"""tenant-app.py <in.app> <out.app> <tenant>

Write a copy of a Business Central .app whose package ID is derived from
(original package ID, tenant).

On a multitenant NST an app published through the dev endpoint belongs to one
tenant, and the NST refuses the same package ID for a second tenant ("A duplicate
package ID is detected"), so the same .app cannot simply be published to two
tenants. The package ID is a GUID in the 40-byte NAVX header at offset 12 and
nothing else in the file refers to it, so a per-tenant ID is enough. It is
deterministic: publishing the same .app to the same tenant twice yields the same
package, which BC treats as an already-published duplicate, as it does in a
single-tenant container.
"""
import hashlib
import sys


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write(__doc__)
        return 2
    src, dst, tenant = sys.argv[1:4]
    data = bytearray(open(src, "rb").read())
    if data[:4] != b"NAVX" or len(data) < 40:
        sys.stderr.write("tenant-app.py: %s is not a Business Central .app\n" % src)
        return 1
    data[12:28] = hashlib.md5(bytes(data[12:28]) + tenant.encode()).digest()
    open(dst, "wb").write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
