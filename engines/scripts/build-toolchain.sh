#!/bin/bash
#
# build-toolchain.sh: builds the Windows-side cross compiler, MinGW-w64 GCC, from pinned
# sources (milestone M1).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/build-toolchain.sh INPUTS_DIR OUTPUT_DIR ARCH
#   ARCH is x86_64 or i686. Installs OUTPUT_DIR/mingw-gcc-ARCH/ with
#   bin/ARCH-w64-mingw32-{gcc,g++,ld,as,ar,dlltool,windres,...}, the MinGW-w64 headers and
#   runtime, and licenses/ (what of the toolchain ends up inside built programs).
#
# Why GCC: CodeWeavers builds CrossOver's Wine with MinGW-w64 GCC 13.2.0 and GNU ld 2.41
# (both are recorded in every DLL CrossOver ships). Built with llvm-mingw (Clang) instead,
# CodeWeavers' kernelbase.dll keeps Steam from ever signing in and the Rockstar Games
# Launcher from installing Social Club; the same source built with GCC works. See
# SCHNITZEL_PLAN.md ("Toolchain"). The versions here match CrossOver's:
#   binutils 2.41, GCC 13.2.0 (with GMP 6.3.0, MPFR 4.2.1, MPC 1.3.1 built in-tree),
#   MinGW-w64 v11.0.1 (headers and runtime), win32 threads, DWARF-2 exceptions on i686.

source "$(dirname "$0")/common.sh"

inputs="${1:?usage: build-toolchain.sh INPUTS_DIR OUTPUT_DIR ARCH}"
output="${2:?usage: build-toolchain.sh INPUTS_DIR OUTPUT_DIR ARCH}"
arch="${3:?usage: build-toolchain.sh INPUTS_DIR OUTPUT_DIR ARCH}"
case "$arch" in
    x86_64) crt_flags=(--disable-lib32 --enable-lib64); gcc_flags=() ;;
    i686)   crt_flags=(--enable-lib32 --disable-lib64); gcc_flags=(--disable-sjlj-exceptions --with-dwarf2) ;;
    *) echo "error: ARCH must be x86_64 or i686" >&2; exit 1 ;;
esac
target="$arch-w64-mingw32"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
prefix="$output/mingw-gcc-$arch"
work="$output/work-toolchain-$arch"
rm -rf "$prefix" "$work"
mkdir -p "$prefix/licenses" "$work"

# The bundled zlib in binutils and GCC doesn't compile with the macOS 26 SDK (its fdopen macro
# clashes with <stdio.h>), so both use the Mac's own zlib (--with-system-zlib), as Homebrew does.
# These are tools that run on this Mac, not part of the engine: build them with the plain
# host compiler and without the engine's flags (deployment target, availability errors).
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
export CC=clang CXX=clang++
# The manuals (.info) aren't needed, and the runners have no Texinfo: when make decides a manual
# is out of date (the unpacked files' times can make it think so), it would fail with error 127.
export MAKEINFO=true   # also passed to make below: configure resets it when its version check fails
export PATH="$prefix/bin:$PATH"

step "binutils $(input_field binutils version)"
unpack "$(input_archive "$inputs" binutils)" "$work/binutils"
mkdir -p "$work/binutils-build"
(cd "$work/binutils-build" && "$work/binutils/configure" --prefix="$prefix" --target="$target" --with-sysroot="$prefix" \
    --disable-multilib --disable-nls --disable-werror --enable-deterministic-archives \
    --disable-gdb --disable-gdbserver --disable-sim --disable-gprofng --with-system-zlib > configure.log \
    && make MAKEINFO=true -j"$JOBS" > make.log && make MAKEINFO=true install > install.log) \
    || { tail -40 "$work/binutils-build/"*.log >&2; exit 1; }

step "MinGW-w64 headers $(input_field mingw-w64 version)"
unpack "$(input_archive "$inputs" mingw-w64)" "$work/mingw-w64"
mkdir -p "$work/headers-build"
(cd "$work/headers-build" && "$work/mingw-w64/mingw-w64-headers/configure" \
    --prefix="$prefix/$target" --host="$target" > configure.log && make install > install.log) \
    || { tail -40 "$work/headers-build/"*.log >&2; exit 1; }
# The documented MinGW-w64 layout: GCC and binutils use PREFIX as sysroot and look for the
# target's headers and libraries in PREFIX/mingw (the target's folder).
ln -sfn "$target" "$prefix/mingw"

step "GCC $(input_field gcc version), compiler only"
unpack "$(input_archive "$inputs" gcc)" "$work/gcc"
unpack "$(input_archive "$inputs" gmp)" "$work/gcc/gmp"
unpack "$(input_archive "$inputs" mpfr)" "$work/gcc/mpfr"
unpack "$(input_archive "$inputs" mpc)" "$work/gcc/mpc"
mkdir -p "$work/gcc-build"
(cd "$work/gcc-build" && "$work/gcc/configure" --prefix="$prefix" --target="$target" \
    --enable-languages=c,c++ --disable-multilib --disable-nls --disable-werror \
    --enable-threads=win32 --enable-shared --enable-static --without-isl --disable-libstdcxx-pch \
    --with-sysroot="$prefix" --with-system-zlib "${gcc_flags[@]+"${gcc_flags[@]}"}" > configure.log \
    && make MAKEINFO=true -j"$JOBS" all-gcc > make-gcc.log && make MAKEINFO=true install-gcc > install-gcc.log) \
    || { tail -60 "$work/gcc-build/"*.log >&2; exit 1; }

step "MinGW-w64 runtime"
mkdir -p "$work/crt-build"
(cd "$work/crt-build" && "$work/mingw-w64/mingw-w64-crt/configure" --prefix="$prefix/$target" \
    --host="$target" "${crt_flags[@]}" > configure.log \
    && make -j"$JOBS" > make.log && make install > install.log) \
    || { tail -40 "$work/crt-build/"*.log >&2; exit 1; }

step "GCC runtime libraries (libgcc, libstdc++)"
(cd "$work/gcc-build" && make MAKEINFO=true -j"$JOBS" > make.log && make MAKEINFO=true install > install.log) \
    || { tail -60 "$work/gcc-build/make.log" >&2; exit 1; }

step "Licenses"
cp "$work/gcc/COPYING3" "$prefix/licenses/GCC-COPYING3"
cp "$work/gcc/COPYING.RUNTIME" "$prefix/licenses/GCC-COPYING.RUNTIME"
cp "$work/mingw-w64/COPYING" "$prefix/licenses/mingw-w64-COPYING"
cp "$work/mingw-w64/mingw-w64-crt/COPYING" "$prefix/licenses/mingw-w64-crt-COPYING" 2>/dev/null || true
cp "$work/mingw-w64/mingw-w64-headers/COPYING" "$prefix/licenses/mingw-w64-headers-COPYING" 2>/dev/null || true

step "Check the toolchain"
version="$("$prefix/bin/$target-gcc" -dumpversion)"
[[ "$version" == "$(input_field gcc version)" ]] || { echo "error: built GCC $version, expected $(input_field gcc version)" >&2; exit 1; }
ld_version="$("$prefix/bin/$target-ld" --version | awk 'NR==1{print $NF}')"
[[ "$ld_version" == "$(input_field binutils version)" ]] || { echo "error: built ld $ld_version" >&2; exit 1; }
printf 'int main(void){return 0;}\n' > "$work/t.c"
"$prefix/bin/$target-gcc" -o "$work/t.exe" "$work/t.c"
LC_ALL=C grep -aq "GCC: (GNU) $version" "$work/t.exe" || { echo "error: test program has no GCC $version marker" >&2; exit 1; }
printf '%s\n' "binutils $(input_field binutils version)" "gcc $version" "mingw-w64 $(input_field mingw-w64 version)" > "$prefix/versions.txt"
echo "ok      $target-gcc $version, ld $ld_version, MinGW-w64 $(input_field mingw-w64 version)"
summary "- Toolchain $target: GCC $version, binutils $ld_version, MinGW-w64 $(input_field mingw-w64 version)"
rm -rf "$work"
