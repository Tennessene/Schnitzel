#!/usr/bin/env python3
#
# check-pe-compiler.py: checks that every Windows-side (PE) file of an engine was built with
# the pinned MinGW-w64 GCC, and none with another compiler (M4, see SCHNITZEL_PLAN.md,
# "Toolchain": CodeWeavers' kernelbase.dll built with Clang breaks Steam and the Rockstar
# Games Launcher).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: check-pe-compiler.py ENGINE_DIR GCC_VERSION
#   Looks at every file starting with "MZ" in lib/wine/i386-windows and lib/wine/x86_64-windows.
#   GCC records "GCC: (GNU) <version>" in each object file it compiles; the check fails if a
#   file has another GCC version or any Clang marker, if one of the core DLLs below lacks the
#   expected marker, or if a file imports one of GCC's or MinGW's runtime DLLs (the engine ships
#   none; libgcc must be linked in statically). Every other file must carry the marker too,
#   except the few in NO_CODE: type libraries, resource-only and forwarding modules with no
#   compiled C code (the same ones CrossOver 26.3's Wine has without a marker). Clang builds
#   often carry no marker at all, so "no marker" is only accepted for those names.

import os
import re
import sys

CORE = ("ntdll.dll", "kernelbase.dll", "kernel32.dll", "user32.dll", "win32u.dll", "gdi32.dll",
        "ws2_32.dll", "advapi32.dll", "ole32.dll", "wined3d.dll", "winemac.drv", "wineboot.exe")
NO_CODE = {"activeds.tlb", "apisetschema.dll", "icmp.dll", "light.msstyles", "lz32.dll", "mferror.dll",
           "mshtml.tlb", "msimsg.dll", "normaliz.dll", "security.dll", "sfc.dll", "shdoclc.dll",
           "stdole2.tlb", "stdole32.tlb", "tzres.dll", "usp10.dll", "wmi.dll"}
RUNTIME_DLLS = (b"libgcc_s_", b"libstdc++-6.dll", b"libwinpthread-1.dll", b"libssp-0.dll")


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: check-pe-compiler.py ENGINE_DIR GCC_VERSION")
    root, version = sys.argv[1], sys.argv[2]
    expected = f"GCC: (GNU) {version}".encode()
    marker = re.compile(rb"GCC: \([^)]*\) [0-9][0-9.]*")
    problems, checked, unmarked = [], 0, []
    for arch in ("i386-windows", "x86_64-windows"):
        folder = os.path.join(root, "lib", "wine", arch)
        if not os.path.isdir(folder):
            problems.append(f"{arch}: folder missing")
            continue
        for name in sorted(os.listdir(folder)):
            path = os.path.join(folder, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                data = f.read()
            if data[:2] != b"MZ":
                continue
            checked += 1
            rel = f"{arch}/{name}"
            markers = set(marker.findall(data))
            others = sorted(m.decode() for m in markers if m != expected)
            if others:
                problems.append(f"{rel}: built with {', '.join(others)}")
            if expected not in markers:
                if name.lower() in NO_CODE and not markers and name.lower() not in CORE:
                    unmarked.append(rel)
                else:
                    problems.append(f"{rel}: no '{expected.decode()}' marker")
            if b"clang version" in data or b"Apple clang" in data:
                problems.append(f"{rel}: contains a Clang marker")
            for dll in RUNTIME_DLLS:
                if dll in data:
                    problems.append(f"{rel}: depends on {dll.decode()}…")
    for p in problems[:60]:
        print(f"error: {p}", file=sys.stderr)
    if len(problems) > 60:
        print(f"error: … and {len(problems) - 60} more", file=sys.stderr)
    if not checked:
        print("error: no PE files found", file=sys.stderr)
        return 1
    print(f"checked {checked} PE files: {'all compiled ones built with ' + expected.decode() if not problems else str(len(problems)) + ' problems'}"
          f"; {len(unmarked)} contain no compiled code")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
