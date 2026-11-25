#!/bin/bash
#
# check-steam.sh: installs Steam in a fresh prefix with a packaged engine and checks that it
# reaches Steam's servers (M4). No account is needed: Steam connects to a Connection Manager
# before anyone signs in, and logs it in logs/connection_log.txt.
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/check-steam.sh ENGINE_ARCHIVE WORK_DIR
#
# This is the check that would have caught the Clang-built kernelbase.dll (see
# SCHNITZEL_PLAN.md, "Toolchain"): Steam started, showed its window, but never connected.
# Steam's installer comes from Valve's CDN and isn't pinned (Valve replaces it with every
# client update); it's only used for this test, never put into an engine. Its SHA-256 is
# printed so a failing run can be reproduced with the same file.
#
# The environment is the one Schnitzel's WineRuntime builds for a default Pfanne, and the
# prefix gets Schnitzel's built-in program setting for steamwebhelper.exe
# (ProgramDefaults.builtIn in SchnitzelKit).

set -euo pipefail
archive="${1:?usage: check-steam.sh ENGINE_ARCHIVE WORK_DIR}"
work="${2:?usage: check-steam.sh ENGINE_ARCHIVE WORK_DIR}"
installer_url="https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
connect_limit=${STEAM_CONNECT_LIMIT:-600}   # seconds; the first start downloads Steam's client
webhelper_options="--no-sandbox --in-process-gpu --disable-gpu"

[[ -n "$work" && "$work" != "/" ]] || { echo "error: bad WORK_DIR" >&2; exit 1; }
rm -rf "${work:?}"
mkdir -p "$work/logs" "$work/tmp"
work="$(cd "$work" && pwd)"
logs="$work/logs"

tar -xf "$archive" -C "$work"
engine="$(dirname "$(find "$work" -mindepth 2 -maxdepth 2 -name bin -type d | awk 'NR==1')")"
[[ -x "$engine/bin/wine" ]] || { echo "error: no bin/wine in the archive" >&2; exit 1; }
prefix="$work/prefix"
wine_env=(
    "HOME=$HOME" "USER=${USER:-runner}" "LANG=en_US.UTF-8" "TMPDIR=$work/tmp/"
    "PATH=$engine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "WINEPREFIX=$prefix" "WINEDEBUG=-all"
    "DYLD_FALLBACK_LIBRARY_PATH=$engine/lib:$engine/lib/external:/usr/lib"
    "WINEMSYNC=1" "WINEESYNC=1" "ROSETTA_ADVERTISE_AVX=1"
)
wine() { /usr/bin/env -i "${wine_env[@]}" "$engine/bin/wine" "$@"; }
stop() { /usr/bin/env -i "${wine_env[@]}" "$engine/bin/wineserver" -k 2>/dev/null || true; }
trap stop EXIT

echo "== Prefix"
/usr/bin/env -i "${wine_env[@]}" WINEDLLOVERRIDES=mscoree,mshtml= "$engine/bin/wine" wineboot --init > "$logs/wineboot.log" 2>&1
/usr/bin/env -i "${wine_env[@]}" "$engine/bin/wineserver" -w
wine reg add 'HKCU\Software\Wine\AppDefaults\steamwebhelper.exe' /v CommandLineAppend /d "$webhelper_options" /f > "$logs/reg.log" 2>&1
echo "ok      prefix created, program setting for steamwebhelper.exe added"

echo "== Steam installer"
curl --fail --location --silent --show-error --proto '=https' --max-time 300 --retry 3 \
    -o "$work/SteamSetup.exe" "$installer_url"
echo "        SteamSetup.exe $(stat -f %z "$work/SteamSetup.exe") bytes, SHA-256 $(shasum -a 256 "$work/SteamSetup.exe" | awk '{print $1}')"
wine "$work/SteamSetup.exe" /S > "$logs/steamsetup.log" 2>&1
/usr/bin/env -i "${wine_env[@]}" "$engine/bin/wineserver" -w
steam_dir="$prefix/drive_c/Program Files (x86)/Steam"
[[ -f "$steam_dir/steam.exe" ]] || { echo "error: Steam wasn't installed" >&2; exit 1; }
echo "ok      Steam installed"

echo "== Steam reaches its servers"
connection_log="$steam_dir/logs/connection_log.txt"
start=$(date +%s)
wine "$steam_dir/steam.exe" > "$logs/steam.log" 2>&1 &
result=1
while (( $(date +%s) - start < connect_limit )); do
    sleep 5
    if [[ -f "$connection_log" ]] && grep -q "ConnectionCompleted" "$connection_log"; then
        result=0
        break
    fi
done
elapsed=$(( $(date +%s) - start ))
# Keep Steam's own logs for debugging, without account numbers (there is no account here,
# but Steam logs a placeholder ID).
if [[ -d "$steam_dir/logs" ]]; then
    for f in "$steam_dir"/logs/{connection_log,bootstrap_log,webhelper,console_log}.txt; do
        [[ -f "$f" ]] && sed -E 's/\[U:1:[0-9]+\]/[U:1:<id>]/g; s/[0-9]{17}/<id>/g' "$f" > "$logs/steam-$(basename "$f")"
    done
fi
webhelpers="$(ps -axo command | grep -c '[s]teamwebhelper.exe' || true)"
stop
trap - EXIT
if [[ $result == 0 ]]; then
    echo "ok      Steam connected to a Connection Manager after ${elapsed} s ($webhelpers web helper processes)"
    echo "Steam check passed"
else
    echo "error: Steam didn't reach its servers within ${connect_limit} s" >&2
    grep -cE "EConnect called" "$connection_log" 2>/dev/null | sed 's/^/        connection attempts rescheduled: /' >&2 || true
    tail -5 "$logs/steam-bootstrap_log.txt" 2>/dev/null | sed 's/^/        | /' >&2 || true
    exit 1
fi
