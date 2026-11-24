#!/bin/bash
#
# build-moltenvk.sh: builds CodeWeavers' MoltenVK (milestone M3). Needs Xcode.
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/build-moltenvk.sh INPUTS_DIR OUTPUT_DIR
#   Installs OUTPUT_DIR/moltenvk/lib/libMoltenVK.dylib (x86_64), its licenses, and
#   OUTPUT_DIR/moltenvk/revisions.txt (the commit of every dependency it was built with).
#   It has its own folder so CI can cache it apart from the unix libraries.
#
# CodeWeavers changed MoltenVK and the copy of SPIRV-Cross next to it (External/SPIRV-Cross),
# so that copy is used instead of fetching SPIRV-Cross. MoltenVK's fetchDependencies script
# still fetches Vulkan-Headers, glslang, Vulkan-Tools, Volk and cereal from GitHub, each at
# the exact commit listed in the drop's ExternalRevisions folder.

source "$(dirname "$0")/common.sh"

inputs="${1:?usage: build-moltenvk.sh INPUTS_DIR OUTPUT_DIR}"
output="${2:?usage: build-moltenvk.sh INPUTS_DIR OUTPUT_DIR}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
prefix="$output/moltenvk"
work="$output/work-moltenvk"
rm -rf "$work" "$prefix"
mkdir -p "$prefix/lib" "$prefix/licenses" "$work"

command -v xcodebuild > /dev/null || { echo "error: MoltenVK needs Xcode (xcodebuild)" >&2; exit 1; }
xcodebuild -version | awk 'NR==1'

step "Unpack CodeWeavers' MoltenVK"
unpack_crossover "$inputs" moltenvk "$work/moltenvk"
# fetchDependencies deletes External/SPIRV-Cross before linking the given folder there,
# so CodeWeavers' copy is moved out of the way first.
mv "$work/moltenvk/External/SPIRV-Cross" "$work/spirv-cross-codeweavers"
echo "SPIRV-Cross: CodeWeavers' copy (drop revision $(cat "$work/moltenvk/ExternalRevisions/SPIRV-Cross_repo_revision"))"

step "Fetch and build MoltenVK's other dependencies"
(cd "$work/moltenvk" && ./fetchDependencies --macos --spirv-cross-root "$work/spirv-cross-codeweavers")

# Record what was fetched, for BUILDINFO.json.
{
    echo "SPIRV-Cross codeweavers-copy $(cat "$work/moltenvk/ExternalRevisions/SPIRV-Cross_repo_revision")"
    for repo in cereal Vulkan-Headers glslang Vulkan-Tools Volk; do
        echo "$repo $(git -C "$work/moltenvk/External/$repo" remote get-url origin) $(git -C "$work/moltenvk/External/$repo" rev-parse HEAD)"
    done
    for repo in "$work"/moltenvk/External/glslang/External/*/; do
        [[ -d "$repo/.git" ]] && echo "glslang/External/$(basename "$repo") $(git -C "$repo" remote get-url origin) $(git -C "$repo" rev-parse HEAD)"
    done
} > "$work/revisions.txt"
cat "$work/revisions.txt"

step "Build MoltenVK"
# Unset the compiler flags meant for the autotools builds; Xcode sets its own.
(cd "$work/moltenvk" && env -u CFLAGS -u CXXFLAGS -u LDFLAGS -u CC -u CXX \
    make macos MVK_CONFIG_LOG_LEVEL=1)

built="$work/moltenvk/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
[[ -f "$built" ]] || built="$(find "$work/moltenvk/Package" -name libMoltenVK.dylib -path '*macOS*' | awk 'NR==1')"
[[ -f "$built" ]] || { echo "error: libMoltenVK.dylib wasn't built" >&2; exit 1; }

lipo "$built" -thin x86_64 -output "$prefix/lib/libMoltenVK.dylib" 2>/dev/null || cp "$built" "$prefix/lib/libMoltenVK.dylib"
install_name_tool -id "libMoltenVK.dylib" "$prefix/lib/libMoltenVK.dylib"  # Wine dlopens it by this name.
codesign --force --sign - "$prefix/lib/libMoltenVK.dylib"  # install_name_tool breaks the signature.
cp "$work/moltenvk/LICENSE" "$prefix/licenses/MoltenVK-LICENSE"
cp "$work/spirv-cross-codeweavers/LICENSE" "$prefix/licenses/SPIRV-Cross-LICENSE"
cp "$work/revisions.txt" "$prefix/revisions.txt"

step "Check MoltenVK"
archs="$(lipo -archs "$prefix/lib/libMoltenVK.dylib")"
[[ "$archs" == "x86_64" ]] || { echo "error: libMoltenVK.dylib is '$archs', not x86_64" >&2; exit 1; }
if otool -L "$prefix/lib/libMoltenVK.dylib" | tail -n +3 | awk '{print $1}' | grep -vE '^(/usr/lib|/System/Library)/'; then
    echo "error: libMoltenVK.dylib links to libraries outside the system" >&2
    exit 1
fi
nm -gU "$prefix/lib/libMoltenVK.dylib" | grep -q ' _vkGetInstanceProcAddr$' \
    || { echo "error: libMoltenVK.dylib doesn't export vkGetInstanceProcAddr" >&2; exit 1; }
version="$(grep -E '#define MVK_VERSION_(MAJOR|MINOR|PATCH) ' "$work/moltenvk/MoltenVK/MoltenVK/API/mvk_private_api.h" | awk '{print $3}' | paste -sd. -)" || version="unknown"
echo "ok      libMoltenVK.dylib $version (CodeWeavers), $archs"
summary "- MoltenVK: $version (CodeWeavers' copy), x86_64"
rm -rf "$work"
