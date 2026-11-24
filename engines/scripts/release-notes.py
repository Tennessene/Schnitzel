#!/usr/bin/env python3
#
# release-notes.py: writes the notes for a Schnitzel engine release (M5).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: release-notes.py BUILDINFO_JSON SHA256SUMS RUN_URL > notes.md
#   BUILDINFO_JSON  the BUILDINFO.json from the engine archive
#   SHA256SUMS      the checksum file attached to the release
#   RUN_URL         the GitHub Actions run that built and checked the engine

import json
import sys


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: release-notes.py BUILDINFO_JSON SHA256SUMS RUN_URL")
    info = json.load(open(sys.argv[1]))
    sums = [line.split() for line in open(sys.argv[2]).read().splitlines() if line.strip()]
    run_url = sys.argv[3]
    version = info["version"]
    wine = next(i for i in info["inputs"] if i["id"] == "crossover-sources")
    wine_upstream = info["wine"]

    out = []
    w = out.append
    w(f"Schnitzel engine **{version}**: Wine {wine_upstream} built from CodeWeavers' Wine source "
      f"(CrossOver {wine['version']} source drop) by this repository's open build scripts.")
    w("")
    w("**Early build.** It is offered in Schnitzel under *Schnitzel engines*, but not recommended yet. "
      "Sikarugir's 10.0_8 engine stays the recommended engine until this engine also plays game videos "
      "(GStreamer, milestone M7) and has been tested on Apple Silicon.")
    w("")
    w("## What's in it")
    w("")
    w("- Wine with CodeWeavers' changes: **MSync** (turned on with `WINEMSYNC=1`, which Schnitzel sets for "
      "the default Sync setting), the **Mac driver hooks D3DMetal uses**, and CodeWeavers' Mac fixes.")
    w("- **32-bit and 64-bit** Windows programs (WoW64). x86_64 only: on Apple Silicon it runs under Rosetta 2.")
    w("- Its own runtime libraries: FreeType, GnuTLS (CodeWeavers' copy), GMP, SDL2, libinotify and "
      "MoltenVK (CodeWeavers' copy). Pfannen using it don't need the separate runtime-libraries component.")
    w("- **No D3DMetal.** Apple doesn't allow it to be redistributed. Import your own from Apple's Game "
      "Porting Toolkit in Schnitzel's Components window.")
    w("")
    w("Not in this build yet: GStreamer (some games' videos won't play), vkd3d and Schnitzel's own DXVK build (M6).")
    w("")
    w("## Checks this build passed")
    w("")
    w("- Package check: the Wine loader's memory layout, every library link stays inside the engine, "
      "everything ad-hoc signed, no D3DMetal, CodeWeavers' MSync and D3DMetal support compiled in.")
    w("- Prefix check on an Intel Mac and on an Apple Silicon Mac (Rosetta 2): `wineboot` creates a "
      "complete prefix with MSync running, `winecfg`, `cmd` and `reg` work, and a 32-bit and a 64-bit "
      "test program run with the expected output.")
    w(f"- Build and checks: {run_url}")
    w("")
    w("## Files")
    w("")
    w("| File | SHA-256 |")
    w("|---|---|")
    for digest, name in sums:
        w(f"| `{name.lstrip('*')}` | `{digest}` |")
    w("")
    w("The engine archive is the only file Schnitzel downloads. The others are the exact sources it was "
      "built from (Wine and GnuTLS are LGPL; see `SOURCE.md` and `LICENSES/` inside the archive).")
    w("")
    w("## Built from")
    w("")
    w("| Input | Version | License | SHA-256 |")
    w("|---|---|---|---|")
    for i in info["inputs"]:
        w(f"| [{i['name']}]({i['url']}) | {i['version']} | {i['license']} | `{i['sha256'][:16]}…` |")
    w("")
    w(f"Build scripts: {info['buildScripts']}. Toolchain: {info['toolchain']['xcode'].strip()}, "
      f"llvm-mingw {info['toolchain']['llvmMingw']}, macOS {info['toolchain']['deploymentTarget']} or newer. "
      f"Runner: {info['runner']['image']} {info['runner']['imageVersion']}. Schnitzel patches: "
      f"{'none' if not info['patches'] else ', '.join(info['patches'])}.")
    w("")
    w("\"CrossOver\" is a trademark of CodeWeavers. This engine is not made or endorsed by CodeWeavers.")
    print("\n".join(out))


if __name__ == "__main__":
    main()
