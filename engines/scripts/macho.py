#!/usr/bin/env python3
#
# macho.py: finds the Mach-O files in an engine package, rewrites their library links so
# the package is self-contained, and checks the result.
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage:
#   macho.py list  PACKAGE   print every Mach-O file (relative paths)
#   macho.py fix   PACKAGE   rewrite links into the package, drop build-path rpaths, re-sign
#   macho.py check PACKAGE   every link resolves inside PACKAGE or to the system; x86_64 only
#
# "Inside the package" means a file the link points to through @loader_path, @rpath (with
# the file's own LC_RPATHs) or @executable_path (bin/wine or the second-stage loader). A
# plain file name such as libgnutls.30.dylib is also accepted when PACKAGE/lib holds it:
# dyld finds those through DYLD_FALLBACK_LIBRARY_PATH, which Schnitzel points at lib/.

import os
import struct
import subprocess
import sys

MACHO_MAGICS = {0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
EXECUTABLES = ("bin/wine", "lib/wine/x86_64-unix/wine")


def macho_files(root):
    found = []
    for folder, _, names in os.walk(root):
        for name in names:
            path = os.path.join(folder, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                with open(path, "rb") as f:
                    head = f.read(4)
            except OSError:
                continue
            if len(head) == 4 and struct.unpack(">I", head)[0] in MACHO_MAGICS:
                found.append(path)
    return sorted(found)


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def install_id(path):
    lines = run("otool", "-D", path).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def dependencies(path):
    """The libraries PATH links to, without its own install name."""
    own = install_id(path)
    deps = []
    for line in run("otool", "-L", path).splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        name = line.split(" (compatibility")[0].strip()
        if name != own:
            deps.append(name)
    return deps


def rpaths(path):
    result, lines = [], run("otool", "-l", path).splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for follow in lines[i + 1:i + 4]:
                follow = follow.strip()
                if follow.startswith("path "):
                    result.append(follow[5:].rsplit(" (offset", 1)[0])
    return result


def resolve(root, path, link):
    """Where LINK from PATH points to, or None if it can't be resolved inside ROOT."""
    here = os.path.dirname(path)
    if link.startswith("@loader_path/"):
        candidates = [os.path.join(here, link[len("@loader_path/"):])]
    elif link.startswith("@executable_path/"):
        candidates = [os.path.join(root, os.path.dirname(e), link[len("@executable_path/"):]) for e in EXECUTABLES]
    elif link.startswith("@rpath/"):
        candidates = []
        for rp in rpaths(path):
            rp = rp.replace("@loader_path", here)
            if rp.startswith("@executable_path"):
                candidates += [rp.replace("@executable_path", os.path.join(root, os.path.dirname(e))) for e in EXECUTABLES]
            else:
                candidates.append(rp)
        candidates = [os.path.join(c, link[len("@rpath/"):]) for c in candidates]
    elif "/" not in link:
        candidates = [os.path.join(root, "lib", link)]
    else:
        candidates = [link]
    root_real = os.path.realpath(root)
    for c in candidates:
        real = os.path.realpath(c)
        if os.path.exists(real) and (real + "/").startswith(root_real + "/"):
            return real
    return None


def package_index(root):
    """File name -> path of every file in the package that another file can link to."""
    index = {}
    for folder, _, names in os.walk(root):
        for name in names:
            if name.endswith((".dylib", ".so")):
                index.setdefault(name, os.path.join(folder, name))
    return index


def fix(root):
    index = package_index(root)
    changed = 0
    for path in macho_files(root):
        here = os.path.dirname(path)
        args = []
        for link in dependencies(path):
            if link.startswith(SYSTEM_PREFIXES):
                continue
            # Links through @loader_path or @rpath that already resolve stay as they are. A
            # plain name (libinotify.0.dylib) is rewritten too, so a linked library is found
            # without DYLD_FALLBACK_LIBRARY_PATH. (The install names stay plain: Wine
            # dlopens its optional libraries by the name configure recorded.)
            if "/" in link and resolve(root, path, link):
                continue
            target = index.get(os.path.basename(link))
            if target is None:
                raise SystemExit(f"error: {os.path.relpath(path, root)} links to {link}, which isn't in the package")
            new = "@loader_path/" + os.path.relpath(target, here)
            args += ["-change", link, new]
        for rp in rpaths(path):
            if not rp.startswith(("@loader_path", "@executable_path")):
                args += ["-delete_rpath", rp]
        if args:
            run("install_name_tool", *args, path)
            changed += 1
        # Always re-sign: install_name_tool and strip break the linker signature, and an
        # unsigned or badly signed binary is killed on Apple Silicon.
        run("codesign", "--force", "--sign", "-", path)
    print(f"rewrote links in {changed} Mach-O files, re-signed all {len(macho_files(root))}")


def check(root):
    failed = False
    files = macho_files(root)
    for path in files:
        rel = os.path.relpath(path, root)
        archs = run("lipo", "-archs", path).split()
        if archs != ["x86_64"]:
            print(f"error: {rel} is built for {' '.join(archs)}, not x86_64 only", file=sys.stderr)
            failed = True
        for link in dependencies(path):
            if link.startswith(SYSTEM_PREFIXES):
                continue
            if resolve(root, path, link) is None:
                print(f"error: {rel} links to {link}, which doesn't resolve inside the package", file=sys.stderr)
                failed = True
        for rp in rpaths(path):
            if not rp.startswith(("@loader_path", "@executable_path")):
                print(f"error: {rel} has a build-path rpath {rp}", file=sys.stderr)
                failed = True
        signature = subprocess.run(["codesign", "--verify", path], capture_output=True, text=True)
        if signature.returncode != 0:
            print(f"error: {rel} has no valid signature: {signature.stderr.strip()}", file=sys.stderr)
            failed = True
    if not files:
        print("error: no Mach-O files found", file=sys.stderr)
        failed = True
    print(f"checked {len(files)} Mach-O files")
    return 1 if failed else 0


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("list", "fix", "check"):
        raise SystemExit(__doc__ if __doc__ else "usage: macho.py list|fix|check PACKAGE")
    command, root = sys.argv[1], os.path.abspath(sys.argv[2])
    if command == "list":
        for path in macho_files(root):
            print(os.path.relpath(path, root))
    elif command == "fix":
        fix(root)
    else:
        sys.exit(check(root))


if __name__ == "__main__":
    main()
