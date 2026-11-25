#!/bin/bash
#
# check-programs.sh: installs a packaged engine with Schnitzel's own code (schnitzel-cli),
# creates a default Pfanne the way the app does, and checks that the Rockstar Games Launcher
# and Steam work in it (M4). No accounts are needed.
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/check-programs.sh SCHNITZEL_CLI ENGINE_ARCHIVE WORK_DIR [rockstar] [steam]
#   SCHNITZEL_CLI   the built schnitzel-cli (swift build --product schnitzel-cli)
#   ENGINE_ARCHIVE  schnitzel-engine-<version>.tar.xz, with SHA256SUMS or <archive>.sha256 next to it
#   Without program names, both are checked, in the order users are told to install them:
#   the Rockstar Games Launcher first, then Steam.
#
# Why through schnitzel-cli: the first version of this check set up Wine by hand and
# passed, while a Pfanne made by the app failed. The app's default Pfanne runs from an
# engine assembly with DXMT and has DXVK in system32; the hand-made one had neither. Now
# every step (Install from File, the default components, New Pfanne, Run) is the app's code.
#
# What passes:
#   rockstar  the launcher's silent install sets up Social Club (Social Club's DLLs appear),
#             which needs the launcher's own window to start (it uses Direct3D 11).
#   steam     Steam's installer, then Steam's first start: it updates itself, restarts and
#             connects to a Steam Connection Manager (logs/connection_log.txt), while the
#             Rockstar programs from the first check are still running.
# The installers come from Rockstar's and Valve's servers and aren't pinned (they replace them
# with every update); they are only used for this test, never put into an engine. Their
# SHA-256 is printed so a failing run can be reproduced with the same files.

set -euo pipefail
cli="${1:?usage: check-programs.sh SCHNITZEL_CLI ENGINE_ARCHIVE WORK_DIR [rockstar] [steam]}"
archive="${2:?usage: check-programs.sh SCHNITZEL_CLI ENGINE_ARCHIVE WORK_DIR [rockstar] [steam]}"
work="${3:?usage: check-programs.sh SCHNITZEL_CLI ENGINE_ARCHIVE WORK_DIR [rockstar] [steam]}"
shift 3
programs=("$@")
(( ${#programs[@]} )) || programs=(rockstar steam)
# The graphics components a user downloads in Components. Pinned here so a new upstream
# release can't change a check's result without a commit.
dxmt_version="dxmt-v0.80"
dxvk_version="dxvk-macos-v1.10.3-20230507-repack"
rockstar_url="https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe"
steam_url="https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
# Seconds. Passing runs on Anston's Mac took 60-156 s (Rockstar, which downloads Social Club)
# and 116-209 s (Steam, which downloads a 336 MB update and restarts itself three times). The
# 3-CPU Apple Silicon runner, where everything runs under Rosetta, needed more than 240 s for
# Rockstar, so the limits leave room. The DXMT failure is still caught within seconds.
rockstar_limit=${ROCKSTAR_LIMIT:-480}
steam_limit=${STEAM_CONNECT_LIMIT:-600}

[[ -n "$work" && "$work" != "/" ]] || { echo "error: bad WORK_DIR" >&2; exit 1; }
rm -rf "${work:?}"
mkdir -p "$work/inbox" "$work/logs"
work="$(cd "$work" && pwd)"
# Short on purpose: Wine can't load DLLs whose full path is longer than 260 characters, and
# the engine assembly's path is long.
export SCHNITZEL_DATA_DIR="$work/d"
pfanne="Check"
drive_c="$SCHNITZEL_DATA_DIR/Application Support/Pfannen/$pfanne/prefix/drive_c"
cleanup() {
    "$cli" stop "$pfanne" > /dev/null 2>&1 || true
    # Keep the Pfanne's run logs and the programs' own logs for debugging.
    cp -R "$SCHNITZEL_DATA_DIR/Logs/." "$work/logs/" 2>/dev/null || true
    mkdir -p "$work/logs/rockstar"
    # The installer's and launcher's own logs (not Social Club's browser cache), the Visual C++
    # installers' logs, and what got installed.
    find "$drive_c/users" -type f \( -ipath "*/Rockstar Games/*" -not -ipath "*/Renderer/*" \
        \( -iname "*.log" -o -iname "*.txt" -o -iname "*.json" \) -o -iname "dd_vcredist*.log" \) \
        -exec cp {} "$work/logs/rockstar/" \; 2>/dev/null || true
    find "$drive_c/Program Files/Rockstar Games" -maxdepth 2 > "$work/logs/rockstar/installed.txt" 2>&1 || true
}
trap cleanup EXIT

echo "== Components, installed as the app does"
cp "$archive" "$work/inbox/"
name="$(basename "$archive")"
if [[ -f "$(dirname "$archive")/SHA256SUMS" ]]; then
    cp "$(dirname "$archive")/SHA256SUMS" "$work/inbox/"
else
    # The workflow's artifact carries <archive>.sha256 instead; Install from File reads SHA256SUMS.
    awk -v n="$name" '{print $1 "  " n}' "$archive.sha256" > "$work/inbox/SHA256SUMS"
fi
engine="$("$cli" install engine "$work/inbox/$name" | awk '/^installed/{print $2}')"
echo "ok      $engine installed from file"
"$cli" download dxmt "$dxmt_version"
"$cli" download dxvk "$dxvk_version"

echo "== New Pfanne"
"$cli" create "$pfanne" --engine "$engine"
"$cli" env "$pfanne" | grep -E '^(engine root|CX_ACTIVE_GRAPHICS_BACKEND|WINEMSYNC|ROSETTA_ADVERTISE_AVX)' | sed 's/^/        /'

fetch() {
    curl --fail --location --silent --show-error --proto '=https' --max-time 600 --retry 3 -o "$2" "$1"
    echo "        downloaded $(basename "$2") ($(stat -f %z "$2") bytes, SHA-256 $(shasum -a 256 "$2" | awk '{print $1}'))"
}

failed=0
for program in "${programs[@]}"; do
    case "$program" in
    rockstar)
        echo "== Rockstar Games Launcher sets up Social Club"
        fetch "$rockstar_url" "$work/inbox/Rockstar-Games-Launcher.exe"
        "$cli" run "$pfanne" "$work/inbox/Rockstar-Games-Launcher.exe" /silent > "$work/logs/rockstar-cli.txt" 2>&1 &
        social_club="$drive_c/Program Files/Rockstar Games/Social Club"
        start=$(date +%s); ok=0
        while (( $(date +%s) - start < rockstar_limit )); do
            sleep 5
            if ls "$social_club"/*.dll > /dev/null 2>&1; then ok=1; break; fi
            # DXMT's d3d11 lacks this; the launcher never gets further (seen every time).
            if grep -q "SwapDeviceContextState" "$SCHNITZEL_DATA_DIR/Logs/$pfanne/"*Rockstar*.log 2>/dev/null; then break; fi
        done
        if (( ok )); then
            echo "ok      Social Club set up after $(( $(date +%s) - start )) s"
        else
            echo "error: the Rockstar Games Launcher didn't set up Social Club within ${rockstar_limit} s" >&2
            grep -h -E "UNIMPLEMENTED|SwapDeviceContextState|RtlpWaitForCriticalSection" "$SCHNITZEL_DATA_DIR/Logs/$pfanne/"*.log 2>/dev/null \
                | sort | uniq -c | head -5 | sed 's/^/        | /' >&2 || true
            failed=1
        fi
        ;;
    steam)
        echo "== Steam installs, updates itself and reaches its servers"
        fetch "$steam_url" "$work/inbox/SteamSetup.exe"
        "$cli" run "$pfanne" "$work/inbox/SteamSetup.exe" /S > "$work/logs/steamsetup-cli.txt" 2>&1
        steam_dir="$drive_c/Program Files (x86)/Steam"
        [[ -f "$steam_dir/steam.exe" ]] || { echo "error: Steam wasn't installed" >&2; failed=1; continue; }
        "$cli" run "$pfanne" "$steam_dir/steam.exe" > "$work/logs/steam-cli.txt" 2>&1 &
        connection_log="$steam_dir/logs/connection_log.txt"
        start=$(date +%s); ok=0
        while (( $(date +%s) - start < steam_limit )); do
            sleep 5
            if [[ -f "$connection_log" ]] && grep -q "ConnectionCompleted" "$connection_log"; then ok=1; break; fi
            # No early stop when steam.exe disappears: Steam exits with code 42 after each update
            # and starts a new copy of itself (once as "Steam.exe"), three times on a first run,
            # and a process check stopped it in the middle of extracting an update.
        done
        # Steam's own logs, without account numbers (there is no account, but Steam logs a placeholder ID).
        for f in "$steam_dir"/logs/{connection_log,bootstrap_log,webhelper,console_log}.txt; do
            [[ -f "$f" ]] && sed -E 's/\[U:1:[0-9]+\]/[U:1:<id>]/g; s/[0-9]{17}/<id>/g' "$f" > "$work/logs/steam-$(basename "$f")"
        done
        if (( ok )); then
            echo "ok      Steam connected to a Connection Manager after $(( $(date +%s) - start )) s"
        else
            echo "error: Steam didn't reach its servers within ${steam_limit} s" >&2
            tail -3 "$work/logs/steam-bootstrap_log.txt" 2>/dev/null | sed 's/^/        | /' >&2 || true
            failed=1
        fi
        ;;
    *) echo "error: unknown program $program" >&2; exit 1 ;;
    esac
done

(( failed )) && { echo "program check failed" >&2; exit 1; }
echo "program check passed"
