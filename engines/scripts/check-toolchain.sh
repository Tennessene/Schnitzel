#!/bin/bash
#
# check-toolchain.sh: proves the pinned MinGW-w64 GCC builds 32-bit and 64-bit Windows
# programs. The two test programs are kept for the prefix check (M4).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/check-toolchain.sh INPUTS_DIR OUTPUT_DIR
#   INPUTS_DIR  folder with the fetched inputs (fetch.py --dest); only inputs.json is read
#   OUTPUT_DIR  holds mingw-gcc-i686 and mingw-gcc-x86_64 (build-toolchain.sh); the test
#               programs are written to OUTPUT_DIR/test-programs

set -euo pipefail

inputs_dir="${1:?usage: check-toolchain.sh INPUTS_DIR OUTPUT_DIR}"
output_dir="${2:?usage: check-toolchain.sh INPUTS_DIR OUTPUT_DIR}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
gcc_version="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(e["version"] for e in d["inputs"] if e["id"]=="gcc"))' "$repo/engines/inputs.json")"
mkdir -p "$output_dir/test-programs"

source="$repo/engines/test-programs/schnitzel-test.c"
failed=0
for arch in i686 x86_64; do
    compiler="$output_dir/mingw-gcc-$arch/bin/$arch-w64-mingw32-gcc"
    [[ -x "$compiler" ]] || { echo "error: $compiler is missing; run build-toolchain.sh first" >&2; exit 1; }
    program="$output_dir/test-programs/schnitzel-test-$arch.exe"
    # -static: the programs must not need libgcc or libwinpthread DLLs in the prefix.
    "$compiler" -O2 -Wall -Werror -static -o "$program" "$source"

    description="$(file -b "$program")"
    case "$arch" in
        i686)   expected_format="PE32 executable";  expected_machine="Intel 80386" ;;
        x86_64) expected_format="PE32+ executable"; expected_machine="x86-64" ;;
    esac
    if [[ "$description" == *"$expected_format"* && "$description" == *"$expected_machine"* ]]; then
        echo "ok      $arch: $description"
    else
        echo "error: $arch program is the wrong kind: $description" >&2
        failed=1
    fi
    if LC_ALL=C grep -aq "GCC: (GNU) $gcc_version" "$program"; then
        echo "ok      $arch: built with GCC $gcc_version"
    else
        echo "error: $arch program wasn't built with GCC $gcc_version" >&2
        failed=1
    fi
done
[[ $failed == 0 ]] || exit 1

version="$("$output_dir/mingw-gcc-x86_64/bin/x86_64-w64-mingw32-gcc" --version | awk 'NR==1')"
echo "toolchain: $version"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### Toolchain"
        echo ""
        echo "- Compiler: \`$version\` (MinGW-w64 GCC, like CrossOver)"
        echo "- Test programs: \`schnitzel-test-i686.exe\` (32-bit), \`schnitzel-test-x86_64.exe\` (64-bit)"
    } >> "$GITHUB_STEP_SUMMARY"
fi
