#!/bin/bash
#
# check-toolchain.sh: unpacks the pinned llvm-mingw and proves it builds 32-bit and 64-bit
# Windows programs. The two test programs are kept for the prefix check (M4).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/check-toolchain.sh INPUTS_DIR OUTPUT_DIR
#   INPUTS_DIR  folder with the fetched inputs (fetch.py --dest)
#   OUTPUT_DIR  where the toolchain is unpacked and the test programs are written

set -euo pipefail

inputs_dir="${1:?usage: check-toolchain.sh INPUTS_DIR OUTPUT_DIR}"
output_dir="${2:?usage: check-toolchain.sh INPUTS_DIR OUTPUT_DIR}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"

# The archive name comes from inputs.json, so there's one place to change the version.
archive_name="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(e["file"] for e in d["inputs"] if e["id"]=="llvm-mingw"))' "$repo/engines/inputs.json")"
archive="$inputs_dir/$archive_name"
[[ -f "$archive" ]] || { echo "error: $archive not found; run fetch.py first" >&2; exit 1; }

# Check the archive again here, so this script is safe to run on its own.
python3 "$repo/engines/scripts/fetch.py" --dest "$inputs_dir" --only llvm-mingw > /dev/null

toolchain="$output_dir/llvm-mingw"
rm -rf "$toolchain"
mkdir -p "$toolchain" "$output_dir/test-programs"
tar -xf "$archive" -C "$toolchain" --strip-components 1

source="$repo/engines/test-programs/schnitzel-test.c"
failed=0
for arch in i686 x86_64; do
    compiler="$toolchain/bin/$arch-w64-mingw32-clang"
    program="$output_dir/test-programs/schnitzel-test-$arch.exe"
    "$compiler" -O2 -Wall -Werror -o "$program" "$source"

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
done
[[ $failed == 0 ]] || exit 1

version="$("$toolchain/bin/x86_64-w64-mingw32-clang" --version | head -1)"
echo "toolchain: $version"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### Toolchain"
        echo ""
        echo "- llvm-mingw: \`$archive_name\`"
        echo "- Compiler: \`$version\`"
        echo "- Test programs: \`schnitzel-test-i686.exe\` (32-bit), \`schnitzel-test-x86_64.exe\` (64-bit)"
    } >> "$GITHUB_STEP_SUMMARY"
fi
