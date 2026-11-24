#!/bin/bash
#
# check-prefix.sh: creates a fresh Wine prefix with a packaged engine, the way Schnitzel
# does, and checks that it works (M4). Required before any engine release.
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/check-prefix.sh ENGINE_ARCHIVE TEST_PROGRAMS_DIR WORK_DIR
#   ENGINE_ARCHIVE     schnitzel-engine-<version>.tar.xz
#   TEST_PROGRAMS_DIR  schnitzel-test-i686.exe and schnitzel-test-x86_64.exe (check-toolchain.sh)
#   WORK_DIR           scratch folder; the engine is unpacked and the prefix created here
#
# The environment is the one Schnitzel's WineRuntime builds (nothing inherited from the
# shell), with MSync on as in a default Pfanne:
#   HOME, USER, LANG, TMPDIR, PATH=<engine>/bin:/usr/bin:/bin:/usr/sbin:/sbin, WINEPREFIX,
#   WINEDEBUG=fixme-all, DYLD_FALLBACK_LIBRARY_PATH=<engine>/lib:<engine>/lib/external:/usr/lib,
#   WINEMSYNC=1, WINEESYNC=1; and WINEDLLOVERRIDES=mscoree,mshtml= for wineboot only (Schnitzel
#   doesn't install Mono or Gecko while creating a Pfanne).
# It runs on Intel and on Apple Silicon under Rosetta 2.

set -euo pipefail
archive="${1:?usage: check-prefix.sh ENGINE_ARCHIVE TEST_PROGRAMS_DIR WORK_DIR}"
programs="$(cd "${2:?usage: check-prefix.sh ENGINE_ARCHIVE TEST_PROGRAMS_DIR WORK_DIR}" && pwd)"
work="${3:?usage: check-prefix.sh ENGINE_ARCHIVE TEST_PROGRAMS_DIR WORK_DIR}"
rm -rf "$work"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
logs="$work/logs"
mkdir -p "$logs"
failed=0
fail() { echo "error: $*" >&2; failed=1; }
ok() { echo "ok      $*"; }

echo "== Machine"
echo "        $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m) hardware: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
if [[ "$(uname -m)" == "arm64" ]]; then
    # Rosetta must be installed to run the x86_64 engine.
    arch -x86_64 /usr/bin/true 2>/dev/null && ok "Rosetta 2 is installed" || { echo "error: Rosetta 2 isn't installed" >&2; exit 1; }
fi

echo "== Unpack $(basename "$archive")"
tar -xf "$archive" -C "$work"
engine="$(find "$work" -mindepth 2 -maxdepth 2 -name bin -type d | awk 'NR==1')"
engine="$(dirname "$engine")"
[[ -x "$engine/bin/wine" ]] || { echo "error: no bin/wine in the archive" >&2; exit 1; }
ok "engine $(cat "$engine/version") at $engine"

prefix="$work/prefix"
tmp="$work/tmp"
mkdir -p "$tmp"
# The variables are passed as arguments to env, which then execs Wine: SIP strips DYLD_*
# variables from protected programs' environments, so they mustn't be inherited through one.
wine_env=(
    "HOME=$HOME" "USER=${USER:-runner}" "LANG=en_US.UTF-8" "TMPDIR=$tmp/"
    "PATH=$engine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "WINEPREFIX=$prefix" "WINEDEBUG=fixme-all"
    "DYLD_FALLBACK_LIBRARY_PATH=$engine/lib:$engine/lib/external:/usr/lib"
    "WINEMSYNC=1" "WINEESYNC=1"
)

# run_wine SECONDS LOGNAME [VAR=VALUE ...] -- PROGRAM ARGS...: runs a Wine program with a
# time limit (macOS has no timeout command). Sets $status and leaves output in the log.
run_wine() {
    local seconds="$1" log="$logs/$2.log" extra=()
    shift 2
    while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done
    shift
    /usr/bin/env -i "${wine_env[@]}" "${extra[@]+"${extra[@]}"}" "$@" > "$log" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= seconds )); then
            echo "error: $2 still running after $seconds seconds; stopping it" >&2
            kill -9 "$pid" 2>/dev/null || true
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    status=0
    wait "$pid" || status=$?
    echo "        $2: exit $status after ${waited}s"
}

show_log() { sed 's/^/        | /' "$logs/$1.log" | tail -n "${2:-40}"; }

echo "== wineboot --init"
run_wine 600 wineboot WINEDLLOVERRIDES=mscoree,mshtml= -- "$engine/bin/wine" wineboot --init
[[ $status == 0 ]] && ok "wineboot exited 0" || { fail "wineboot exited $status"; show_log wineboot; }
run_wine 300 wineserver-wait -- "$engine/bin/wineserver" -w
[[ $status == 0 ]] || fail "wineserver -w exited $status"
show_log wineboot 15

echo "== The prefix (as Pfanne.prefixState checks it)"
[[ -d "$prefix/drive_c" ]] && ok "drive_c exists" || fail "drive_c is missing"
for hive in system.reg user.reg userdef.reg; do
    [[ -s "$prefix/$hive" ]] && ok "$hive exists" || fail "$hive is missing"
done
count="$(find "$prefix/drive_c/windows/system32" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
(( count >= 50 )) && ok "system32 has $count files" || fail "system32 has only $count files (at least 50 expected)"
count32="$(find "$prefix/drive_c/windows/syswow64" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
(( count32 >= 50 )) && ok "syswow64 has $count32 files" || fail "syswow64 has only $count32 files (at least 50 expected)"

echo "== MSync"
if grep -q "msync: up and running" "$logs"/wineboot.log; then
    ok "wineserver printed \"msync: up and running\""
else
    fail "wineserver didn't report MSync running"
fi
if grep -q "Server is running with WINEMSYNC" "$logs"/*.log; then
    fail "a Wine process disagreed with the server about MSync"
fi

echo "== Windows programs"
run_wine 120 winecfg -- "$engine/bin/wine" winecfg /v
version="$(tr -d '\r' < "$logs/winecfg.log" | grep -E '^win[0-9a-z]+$' | awk 'NR==1' || true)"
[[ $status == 0 && -n "$version" ]] && ok "winecfg /v reports $version" || { fail "winecfg /v didn't print a Windows version"; show_log winecfg; }

run_wine 120 cmd -- "$engine/bin/wine" cmd /c echo schnitzel-ok
if [[ $status == 0 ]] && tr -d '\r' < "$logs/cmd.log" | grep -qx "schnitzel-ok"; then ok "cmd /c echo works"; else fail "cmd /c echo didn't work"; show_log cmd; fi

run_wine 120 reg -- "$engine/bin/wine" reg query 'HKLM\Software\Microsoft\Windows NT\CurrentVersion' /v CurrentBuild
if [[ $status == 0 ]] && grep -q "CurrentBuild" "$logs/reg.log"; then
    ok "reg query: $(tr -d '\r' < "$logs/reg.log" | grep CurrentBuild | awk '{$1=$1; print}')"
else
    fail "reg query failed"; show_log reg
fi

echo "== 32-bit and 64-bit test programs"
check_program() {  # check_program ARCH EXPECTED_LINE
    run_wine 120 "test-$1" -- "$engine/bin/wine" "$programs/schnitzel-test-$1.exe"
    local line
    line="$(tr -d '\r' < "$logs/test-$1.log" | grep '^schnitzel-test ' || true)"
    if [[ $status == 42 && "$line" == "$2" ]]; then
        ok "$1: \"$line\", exit 42"
    else
        fail "$1: expected \"$2\" and exit 42, got \"$line\" and exit $status"
        show_log "test-$1"
    fi
}
check_program x86_64 "schnitzel-test arch=x86_64 bits=64 wow64=no"
check_program i686 "schnitzel-test arch=i686 bits=32 wow64=yes"

run_wine 120 wineserver-kill -- "$engine/bin/wineserver" -k
if [[ $failed != 0 ]]; then
    echo "prefix check FAILED; logs are in $logs" >&2
    exit 1
fi
echo "prefix check passed"
