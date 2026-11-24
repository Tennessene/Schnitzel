#!/bin/bash
#
# common.sh: shared settings and helpers for the engine build scripts. Sourced, not run.
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.

set -euo pipefail

ENGINE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE_INPUTS_JSON="$ENGINE_REPO/engines/inputs.json"

# Everything is built for x86_64: Wine runs under Rosetta on Apple Silicon.
export MACOSX_DEPLOYMENT_TARGET=14.0
export ENGINE_ARCH=x86_64
if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "error: run the engine build on an Intel Mac or under Rosetta: arch -x86_64 /bin/bash $0" >&2
    exit 1
fi

# Using a macOS function newer than the deployment target without a runtime check is an
# error, not a warning: the runner's SDK is newer than macOS 14, and such a call would crash
# on older systems. (configure's link tests can't tell; see build-unix-libs.sh for fixes.)
availability="-Werror=unguarded-availability -Werror=unguarded-availability-new"
export CFLAGS="${CFLAGS:-} -O2 -arch x86_64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET $availability"
export CXXFLAGS="${CXXFLAGS:-} -O2 -arch x86_64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET $availability"
# Leave room in Mach-O headers so install names can be rewritten when packaging.
export LDFLAGS="${LDFLAGS:-} -arch x86_64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Wl,-headerpad_max_install_names"
export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"

JOBS="$(sysctl -n hw.ncpu)"

# input_field ID FIELD: a field of an input in inputs.json.
input_field() {
    python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
e=next((e for e in d["inputs"] if e["id"]==sys.argv[2]), None)
if e is None: sys.exit("unknown input " + sys.argv[2])
print(e[sys.argv[3]])' "$ENGINE_INPUTS_JSON" "$1" "$2"
}

# input_archive INPUTS_DIR ID: the verified archive of an input (verifies it again).
input_archive() {
    python3 "$ENGINE_REPO/engines/scripts/fetch.py" --dest "$1" --only "$2" > /dev/null
    echo "$1/$(input_field "$2" file)"
}

# crossover_path ID COMPONENT: the folder of COMPONENT inside the CrossOver drop.
crossover_path() {
    python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
e=next(e for e in d["inputs"] if e["id"]=="crossover-sources")
print(next(p["path"] for p in e["provides"] if p["component"]==sys.argv[2]))' "$ENGINE_INPUTS_JSON" "$1"
}

# unpack ARCHIVE DEST: unpacks ARCHIVE into DEST, dropping the archive's top folder.
unpack() {
    rm -rf "$2"
    mkdir -p "$2"
    tar -xf "$1" -C "$2" --strip-components 1
}

# unpack_crossover INPUTS_DIR COMPONENT DEST: unpacks one component from the CrossOver drop.
unpack_crossover() {
    local archive path depth
    archive="$(input_archive "$1" crossover-sources)"
    path="$(crossover_path "$2")"
    depth="$(awk -F/ '{print NF}' <<< "$path")"
    rm -rf "$3"
    mkdir -p "$3"
    tar -xf "$archive" -C "$3" --strip-components "$depth" "$path"
}

# step NAME: prints a heading, and a group in GitHub's log.
step() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::endgroup::" 2>/dev/null || true; echo "::group::$1"; fi
    echo "==> $1"
}

# summary TEXT: appends a line to the GitHub job summary, if there is one.
summary() {
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$1" >> "$GITHUB_STEP_SUMMARY"; fi
}
