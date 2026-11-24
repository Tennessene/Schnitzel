#!/bin/bash
#
# check-engine.sh: checks a packaged engine folder before it is archived or released (M4).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/check-engine.sh ENGINE_DIR
#   ENGINE_DIR is the unpacked engine (the folder holding bin/ and lib/).
#
# Checks:
#   - layout: bin/wine, bin/wineserver, lib/wine/{x86_64-unix,x86_64-windows,i386-windows},
#     share/wine, LICENSES/, BUILDINFO.json, SOURCE.md, version;
#   - the macOS loader: the second stage lib/wine/x86_64-unix/wine has a 0x1000 __PAGEZERO,
#     WINE_RESERVE at 0x1000 and WINE_TOP_DOWN at 0x7ff000000000 (see the 11.0_1 lesson
#     in SCHNITZEL_PLAN.md);
#   - every Mach-O file is x86_64 only, signed, and links only to the system or into the
#     package (macho.py check);
#   - Apple's D3DMetal is not in the package (Schnitzel never distributes it);
#   - CodeWeavers' features are compiled in: the D3DMetal hooks in winemac.so, the
#     CX_APPLEGPTK_LIBD3DSHARED_PATH loader code in ntdll.so, and MSync in ntdll.so and
#     wineserver. Strings are used, not symbols, so the check also works on stripped files.

set -euo pipefail
engine="$(cd "${1:?usage: check-engine.sh ENGINE_DIR}" && pwd)"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
failed=0
fail() { echo "error: $*" >&2; failed=1; }
ok() { echo "ok      $*"; }

echo "== Layout"
for path in bin/wine bin/wineserver lib/wine/x86_64-unix/wine lib/wine/x86_64-unix/ntdll.so \
    lib/wine/x86_64-unix/winemac.so lib/wine/x86_64-windows/ntdll.dll lib/wine/i386-windows/ntdll.dll \
    lib/wine/x86_64-windows/wineboot.exe lib/wine/i386-windows/kernel32.dll share/wine/wine.inf \
    BUILDINFO.json SOURCE.md version LICENSES/Wine-COPYING.LIB; do
    [[ -e "$engine/$path" ]] && ok "$path" || fail "$path is missing"
done
for library in libfreetype.6.dylib libgnutls.30.dylib libgmp.10.dylib libSDL2-2.0.0.dylib libinotify.0.dylib libMoltenVK.dylib; do
    [[ -e "$engine/lib/$library" ]] && ok "lib/$library" || fail "lib/$library is missing"
done
if [[ -f "$engine/BUILDINFO.json" ]]; then
    python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$engine/BUILDINFO.json" || fail "BUILDINFO.json isn't valid JSON"
fi

echo "== Loader"
loader="$engine/lib/wine/x86_64-unix/wine"
if [[ -f "$loader" ]]; then
    segment() {  # segment NAME: "vmaddr vmsize" of a segment in the loader
        otool -l "$loader" | awk -v name="$1" '
            $1 == "segname" && $2 == name { found = 1; next }
            found && $1 == "vmaddr" { addr = $2 }
            found && $1 == "vmsize" { print addr, $2; exit }'
    }
    read -r addr size <<< "$(segment __PAGEZERO)"
    [[ "${size:-}" == "0x0000000000001000" || "${size:-}" == "0x1000" ]] && ok "__PAGEZERO size $size" || fail "__PAGEZERO size is '${size:-none}', expected 0x1000"
    read -r addr size <<< "$(segment WINE_RESERVE)"
    [[ "$(( ${addr:-0} ))" == "$(( 0x1000 ))" ]] && ok "WINE_RESERVE at $addr (size $size)" || fail "WINE_RESERVE is at '${addr:-none}', expected 0x1000"
    read -r addr size <<< "$(segment WINE_TOP_DOWN)"
    [[ "$(( ${addr:-0} ))" == "$(( 0x7ff000000000 ))" ]] && ok "WINE_TOP_DOWN at $addr" || fail "WINE_TOP_DOWN is at '${addr:-none}', expected 0x7ff000000000"
fi

echo "== Mach-O files"
python3 -I "$repo/engines/scripts/macho.py" check "$engine" || failed=1

echo "== No D3DMetal"
apple="$(find "$engine" \( -iname 'D3DMetal.framework' -o -iname 'libd3dshared.dylib' -o -iname 'D3DMetal' \) -print)"
[[ -z "$apple" ]] && ok "no D3DMetal.framework or libd3dshared.dylib" || fail "Apple's D3DMetal is in the package: $apple"

echo "== CodeWeavers' features"
has_string() {  # has_string FILE TEXT DESCRIPTION
    if [[ -f "$engine/$1" ]] && LC_ALL=C grep -aqF "$2" "$engine/$1"; then
        ok "$3 ($1 contains \"$2\")"
    else
        fail "$3 missing: $1 doesn't contain \"$2\""
    fi
}
has_string lib/wine/x86_64-unix/winemac.so "macdrv_d3dmtl" "D3DMetal hooks in the Mac driver"
has_string lib/wine/x86_64-unix/ntdll.so "CX_APPLEGPTK_LIBD3DSHARED_PATH" "D3DMetal loader support"
has_string lib/wine/x86_64-unix/ntdll.so "Server is running with WINEMSYNC" "MSync in ntdll"
has_string lib/wine/x86_64-unix/ntdll.so "WINEMSYNC" "MSync switch in ntdll"
has_string bin/wineserver "msync: up and running" "MSync in wineserver"
# Symbols too, where the files still have them (informational).
if nm "$engine/lib/wine/x86_64-unix/ntdll.so" 2>/dev/null | grep -q '_msync_init$'; then ok "ntdll.so has the msync_init symbol"; fi
if nm "$engine/bin/wineserver" 2>/dev/null | grep -q '_msync_init$'; then ok "wineserver has the msync_init symbol"; fi

echo "== Size"
du -sh "$engine" | awk '{print "        " $1 " unpacked"}'

if [[ $failed != 0 ]]; then
    echo "engine check FAILED" >&2
    exit 1
fi
echo "engine check passed"
