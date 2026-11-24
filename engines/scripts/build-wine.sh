#!/bin/bash
#
# build-wine.sh: builds CodeWeavers' Wine from the CrossOver source drop (milestone M4).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/build-wine.sh INPUTS_DIR OUTPUT_DIR
#   Needs OUTPUT_DIR/deps from build-unix-libs.sh and OUTPUT_DIR/moltenvk from build-moltenvk.sh.
#   Installs Wine into OUTPUT_DIR/wine (bin/, lib/wine/, share/wine/).
#
# A WoW64 build (64-bit and 32-bit Windows programs, 64-bit unix side) with llvm-mingw for
# the Windows-side DLLs. CodeWeavers' configure.ac already sets the macOS loader flags (the
# reserved low memory for Windows code); check-engine.sh verifies them afterwards.

source "$(dirname "$0")/common.sh"

inputs="${1:?usage: build-wine.sh INPUTS_DIR OUTPUT_DIR}"
output="${2:?usage: build-wine.sh INPUTS_DIR OUTPUT_DIR}"
output="$(cd "$output" && pwd)"
deps="$output/deps"
moltenvk="$output/moltenvk"
install="$output/wine"
work="$output/work-wine"
[[ -f "$deps/lib/libgnutls.30.dylib" && -f "$moltenvk/lib/libMoltenVK.dylib" ]] \
    || { echo "error: build the libraries and MoltenVK first ($deps, $moltenvk)" >&2; exit 1; }
rm -rf "$install" "$work"
mkdir -p "$work"

step "Toolchain"
toolchain="$output/llvm-mingw"
if [[ ! -x "$toolchain/bin/x86_64-w64-mingw32-clang" ]]; then
    unpack "$(input_archive "$inputs" llvm-mingw)" "$toolchain"
fi
# Wine needs a newer bison and flex than macOS has; Homebrew's are keg-only. They are looked
# up by path, not with brew: under Rosetta on Apple Silicon (the fallback build), Homebrew
# in /opt/homebrew refuses to run, so CI installs them natively before this script.
tool_dir() {  # tool_dir NAME: the bin folder of Homebrew's keg-only NAME
    local prefix
    for prefix in /usr/local /opt/homebrew; do
        [[ -x "$prefix/opt/$1/bin/$1" ]] && { echo "$prefix/opt/$1/bin"; return; }
    done
    if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" != 1 ]] && command -v brew > /dev/null; then
        brew install "$1" >&2 && echo "$(brew --prefix "$1")/bin" && return
    fi
    echo "error: Homebrew's $1 is missing (brew install $1)" >&2
    return 1
}
bison_dir="$(tool_dir bison)"
flex_dir="$(tool_dir flex)"
# llvm-mingw goes last: it has its own unprefixed clang, clang++ and clang-cpp, which can't
# build Mac code. Wine's configure finds the prefixed x86_64-w64-mingw32-clang anywhere in
# PATH. The Mac compilers are named explicitly as well.
export PATH="$bison_dir:$flex_dir:$PATH:$toolchain/bin"
export CC=/usr/bin/clang CXX=/usr/bin/clang++
"$CC" --version | awk 'NR==1' 
x86_64-w64-mingw32-clang --version | awk 'NR==1'
bison --version | awk 'NR==1'
flex --version | awk 'NR==1'

export PKG_CONFIG_PATH="$deps/lib/pkgconfig"
export CPPFLAGS="-I$deps/include"
# The rpaths let build tools that run during the build (sfnt2fon links FreeType) find the
# @rpath libraries. package-engine.sh removes these build paths again.
export LDFLAGS="$LDFLAGS -L$deps/lib -L$moltenvk/lib -Wl,-rpath,$deps/lib -Wl,-rpath,$moltenvk/lib"

step "Unpack CodeWeavers' Wine"
unpack_crossover "$inputs" wine "$work/source"
cat "$work/source/VERSION"

step "Apply Schnitzel's patches"
# engines/patches/wine/*.patch, in file name order. A patch that doesn't apply cleanly fails
# the build; the list goes into BUILDINFO.json (package-engine.sh).
patches=("$ENGINE_REPO"/engines/patches/wine/*.patch)
[[ -e "${patches[0]}" ]] || patches=()
: > "$work/patches.txt"
for patch in "${patches[@]}"; do
    (cd "$work/source" && patch -p1 --forward --batch --quiet < "$patch") \
        || { echo "error: $(basename "$patch") doesn't apply" >&2; exit 1; }
    echo "$(basename "$patch") $(shasum -a 256 "$patch" | awk '{print $1}')" >> "$work/patches.txt"
    echo "ok      $(basename "$patch")"
done

step "Configure"
mkdir -p "$work/build"
cd "$work/build"
configure_args=(
    --enable-archs=i386,x86_64 --with-mingw
    --disable-tests
    --with-coreaudio --with-cups --with-freetype --with-gnutls --with-inotify --with-opencl
    --with-pcap --with-sdl --with-vulkan
    --without-x --without-wayland --without-alsa --without-oss --without-pulse
    --without-capi --without-dbus --without-ffmpeg --without-fontconfig --without-gphoto
    --without-gssapi --without-gstreamer --without-krb5 --without-netapi --without-sane
    --without-udev --without-usb --without-v4l2
)
"$work/source/configure" --prefix="$install" "${configure_args[@]}" 2>&1 | tee "$work/configure.log"

# configure only warns when a library is missing; Schnitzel's engine needs all of these.
config_h="$work/build/include/config.h"
missing=0
# SONAME_LIBVULKAN must name MoltenVK: CrossOver ships no separate Vulkan loader, and
# Wine's configure falls back to MoltenVK when it finds no libvulkan.
for define in SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBVULKAN SONAME_LIBSDL2 HAVE_SYS_INOTIFY_H; do
    if grep -q "^#define $define" "$config_h"; then
        echo "ok      $(grep "^#define $define" "$config_h")"
    else
        echo "error: configure didn't enable $define" >&2
        missing=1
    fi
done
grep -q '^#define SONAME_LIBVULKAN "libMoltenVK.dylib"' "$config_h" \
    || { echo "error: Vulkan isn't MoltenVK: $(grep SONAME_LIBVULKAN "$config_h")" >&2; missing=1; }
# The Windows side must be built for both architectures (WoW64).
grep -q "^PE_ARCHS = .*i386" "$work/build/Makefile" && grep -q "^PE_ARCHS = .*x86_64" "$work/build/Makefile" \
    || { echo "error: configure didn't enable both i386 and x86_64 PE builds: $(grep "^PE_ARCHS" "$work/build/Makefile")" >&2; missing=1; }
# Every recorded library name must be a plain file name: Wine dlopens exactly this string.
if grep -E '^#define SONAME_' "$config_h" | grep -vE '^#define SONAME_[A-Z0-9_]+ "[A-Za-z0-9._+-]+\.dylib"$'; then
    echo "error: configure recorded library names that aren't plain file names (above)" >&2
    missing=1
fi
[[ $missing == 0 ]] || { grep -iE "won't be supported|not found" "$work/configure.log" >&2 || true; exit 1; }

step "Build (this is the long part)"
start=$(date +%s)
make -j"$JOBS" > "$work/make.log" 2>&1 || { tail -80 "$work/make.log" >&2; exit 1; }
echo "built in $(( ($(date +%s) - start) / 60 )) minutes"

step "Install"
make install > "$work/install.log" 2>&1 || { tail -40 "$work/install.log" >&2; exit 1; }
cp "$work/source/COPYING.LIB" "$work/source/LICENSE" "$work/source/AUTHORS" "$install/"
cp "$work/configure.log" "$install/configure.log"
printf '%s\n' "${configure_args[@]}" > "$install/configure-args.txt"
cp "$work/source/VERSION" "$install/wine-version.txt"  # "Wine version 11.0"
cp "$work/patches.txt" "$install/patches.txt"
for arch in i386-windows x86_64-windows x86_64-unix; do
    [[ -d "$install/lib/wine/$arch" ]] || { echo "error: lib/wine/$arch wasn't installed" >&2; exit 1; }
done
summary "- Wine: $(cat "$work/source/VERSION") (CodeWeavers' copy), built in $(( ($(date +%s) - start) / 60 )) minutes"
cd "$output"
rm -rf "$work"
