#!/bin/bash
#
# build-wine.sh: builds CodeWeavers' Wine from the CrossOver source drop (milestone M4).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/build-wine.sh INPUTS_DIR OUTPUT_DIR
#   Needs OUTPUT_DIR/deps from build-unix-libs.sh and build-moltenvk.sh.
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
install="$output/wine"
work="$output/work-wine"
[[ -f "$deps/lib/libgnutls.30.dylib" && -f "$deps/lib/libMoltenVK.dylib" ]] \
    || { echo "error: build the libraries and MoltenVK first ($deps)" >&2; exit 1; }
rm -rf "$install" "$work"
mkdir -p "$work"

step "Toolchain"
toolchain="$output/llvm-mingw"
if [[ ! -x "$toolchain/bin/x86_64-w64-mingw32-clang" ]]; then
    unpack "$(input_archive "$inputs" llvm-mingw)" "$toolchain"
fi
# Wine needs a newer bison and flex than macOS has; Homebrew's are keg-only.
brew_prefix() { brew --prefix "$1" 2>/dev/null || true; }
for tool in bison flex; do
    [[ -x "$(brew_prefix $tool)/bin/$tool" ]] || brew install "$tool"
done
export PATH="$toolchain/bin:$(brew_prefix bison)/bin:$(brew_prefix flex)/bin:$PATH"
x86_64-w64-mingw32-clang --version | head -1
bison --version | head -1
flex --version | head -1

export PKG_CONFIG_PATH="$deps/lib/pkgconfig"
export CPPFLAGS="-I$deps/include"
export LDFLAGS="$LDFLAGS -L$deps/lib"

step "Unpack CodeWeavers' Wine"
unpack_crossover "$inputs" wine "$work/source"
cat "$work/source/VERSION"

step "Configure"
mkdir -p "$work/build"
cd "$work/build"
"$work/source/configure" --prefix="$install" \
    --enable-archs=i386,x86_64 --with-mingw \
    --disable-tests \
    --with-coreaudio --with-cups --with-freetype --with-gnutls --with-inotify --with-opencl \
    --with-pcap --with-sdl --with-vulkan \
    --without-x --without-wayland --without-alsa --without-oss --without-pulse \
    --without-capi --without-dbus --without-ffmpeg --without-fontconfig --without-gphoto \
    --without-gssapi --without-gstreamer --without-krb5 --without-netapi --without-sane \
    --without-udev --without-usb --without-v4l2 \
    2>&1 | tee "$work/configure.log"

# configure only warns when a library is missing; Schnitzel's engine needs all of these.
config_h="$work/build/include/config.h"
missing=0
for define in SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBVULKAN SONAME_LIBSDL2 HAVE_SYS_INOTIFY_H; do
    if grep -q "^#define $define" "$config_h"; then
        echo "ok      $(grep "^#define $define" "$config_h")"
    else
        echo "error: configure didn't enable $define" >&2
        missing=1
    fi
done
[[ $missing == 0 ]] || { grep -iE "won't be supported|not found" "$work/configure.log" >&2 || true; exit 1; }

step "Build (this is the long part)"
start=$(date +%s)
make -j"$JOBS" > "$work/make.log" 2>&1 || { tail -80 "$work/make.log" >&2; exit 1; }
echo "built in $(( ($(date +%s) - start) / 60 )) minutes"

step "Install"
make install > "$work/install.log" 2>&1 || { tail -40 "$work/install.log" >&2; exit 1; }
cp "$work/source/COPYING.LIB" "$work/source/LICENSE" "$work/source/AUTHORS" "$install/"
cp "$work/configure.log" "$install/configure.log"
summary "- Wine: $(cat "$work/source/VERSION") (CodeWeavers' copy), built in $(( ($(date +%s) - start) / 60 )) minutes"
cd "$output"
rm -rf "$work"
