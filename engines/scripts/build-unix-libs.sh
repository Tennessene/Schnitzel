#!/bin/bash
#
# build-unix-libs.sh: builds the libraries Wine loads at runtime, for x86_64 (milestone M2).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/build-unix-libs.sh INPUTS_DIR OUTPUT_DIR
#   Installs into OUTPUT_DIR/deps (lib/, include/, lib/pkgconfig/).
#
# Matches what CrossOver 26.3.0 ships in lib64: GnuTLS (CodeWeavers' copy) with Nettle linked
# in and GMP as its only library dependency, FreeType without extra codecs, SDL2 and
# libinotify-kqueue. GLib and GStreamer follow in M7.

source "$(dirname "$0")/common.sh"

inputs="${1:?usage: build-unix-libs.sh INPUTS_DIR OUTPUT_DIR}"
output="${2:?usage: build-unix-libs.sh INPUTS_DIR OUTPUT_DIR}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
prefix="$output/deps"
work="$output/work-unix"
rm -rf "$prefix" "$work"
mkdir -p "$prefix/lib" "$prefix/include" "$prefix/licenses" "$work"

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export CPPFLAGS="-I$prefix/include"
export LDFLAGS="$LDFLAGS -L$prefix/lib"
configure_common=(--prefix="$prefix" --host=x86_64-apple-darwin --build=x86_64-apple-darwin)

# Install names (set at the end, once everything is built: during the build the libraries
# keep their absolute install names, so configure's test programs can load them). Wine dlopens these libraries by the name configure records, so each one's
# install name is its plain file name (libgnutls.30.dylib). Wine then finds it through
# DYLD_FALLBACK_LIBRARY_PATH, which Schnitzel points at the engine's lib folder. Links
# between the libraries use @loader_path, so they find each other in the same folder.
fix_install_name() {
    local library="$1" name dependency
    name="$(basename "$library")"
    install_name_tool -id "$name" "$library"
    while read -r dependency; do
        [[ -f "$prefix/lib/$(basename "$dependency")" ]] || continue
        install_name_tool -change "$dependency" "@loader_path/$(basename "$dependency")" "$library"
    done < <(otool -L "$library" | tail -n +2 | awk '{print $1}' | grep "^$prefix/lib/\|^@rpath/" | grep -v "/$name\$")
    codesign --force --sign - "$library"  # install_name_tool breaks the signature.
}

step "GMP $(input_field gmp version)"
unpack "$(input_archive "$inputs" gmp)" "$work/gmp"
(cd "$work/gmp" && ./configure "${configure_common[@]}" --enable-shared --disable-static --disable-cxx \
    && make -j"$JOBS" && make install)
cp "$work/gmp/COPYING.LESSERv3" "$prefix/licenses/GMP-COPYING.LESSERv3"
cp "$work/gmp/COPYINGv2" "$prefix/licenses/GMP-COPYINGv2"

step "Nettle $(input_field nettle version) (static, linked into GnuTLS as in CrossOver)"
unpack "$(input_archive "$inputs" nettle)" "$work/nettle"
(cd "$work/nettle" && CFLAGS="$CFLAGS -fPIC" ./configure "${configure_common[@]}" \
    --disable-shared --enable-static --disable-documentation --disable-openssl --enable-mini-gmp=no \
    && make -j"$JOBS" && make install)
cp "$work/nettle/COPYING.LESSERv3" "$prefix/licenses/Nettle-COPYING.LESSERv3"

step "GnuTLS (CodeWeavers' copy from CrossOver $(input_field crossover-sources version))"
unpack_crossover "$inputs" gnutls "$work/gnutls"
# GnuTLS needs the static Nettle and Hogweed plus GMP; its own copies of libtasn1 and
# libunistring are used, and no p11-kit, IDN, zlib, brotli or zstd (CrossOver ships none).
(cd "$work/gnutls" && \
    NETTLE_CFLAGS="-I$prefix/include" NETTLE_LIBS="$prefix/lib/libnettle.a" \
    HOGWEED_CFLAGS="-I$prefix/include" HOGWEED_LIBS="$prefix/lib/libhogweed.a $prefix/lib/libgmp.dylib" \
    GMP_CFLAGS="-I$prefix/include" GMP_LIBS="-L$prefix/lib -lgmp" \
    ./configure "${configure_common[@]}" --enable-shared --disable-static \
        --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn \
        --without-zlib --without-brotli --without-zstd --without-tpm --without-tpm2 \
        --disable-doc --disable-manpages --disable-tools --disable-tests --disable-cxx \
        --disable-guile --disable-nls --disable-valgrind-tests --disable-full-test-suite \
    && make -j"$JOBS" && make install)
cp "$work/gnutls/LICENSE" "$prefix/licenses/GnuTLS-LICENSE"
cp "$work/gnutls/doc/COPYING.LESSER" "$prefix/licenses/GnuTLS-COPYING.LESSER"
cp "$work/gnutls/lib/accelerated/x86/license.txt" "$prefix/licenses/GnuTLS-x86-accelerated-license.txt"

step "FreeType $(input_field freetype version)"
unpack "$(input_archive "$inputs" freetype)" "$work/freetype"
(cd "$work/freetype" && ./configure "${configure_common[@]}" --enable-shared --disable-static \
    --with-zlib=yes --with-bzip2=no --with-png=no --with-harfbuzz=no --with-brotli=no \
    && make -j"$JOBS" && make install)
cp "$work/freetype/LICENSE.TXT" "$prefix/licenses/FreeType-LICENSE.TXT"
cp "$work/freetype/docs/FTL.TXT" "$prefix/licenses/FreeType-FTL.TXT"

step "SDL2 $(input_field sdl2 version)"
unpack "$(input_archive "$inputs" sdl2)" "$work/sdl2"
cmake -S "$work/sdl2" -B "$work/sdl2/build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF -DSDL2_DISABLE_SDL2MAIN=ON
cmake --build "$work/sdl2/build" -j "$JOBS"
cmake --install "$work/sdl2/build"
cp "$work/sdl2/LICENSE.txt" "$prefix/licenses/SDL2-LICENSE.txt"

step "libinotify-kqueue $(input_field libinotify-kqueue version)"
unpack "$(input_archive "$inputs" libinotify-kqueue)" "$work/libinotify"
(cd "$work/libinotify" && ./configure "${configure_common[@]}" --enable-shared --disable-static \
    && make -j"$JOBS" && make install)
cp "$work/libinotify/LICENSE" "$prefix/licenses/libinotify-kqueue-LICENSE"

step "Install names"
for library in libgmp.10.dylib libgnutls.30.dylib libfreetype.6.dylib libSDL2-2.0.0.dylib libinotify.0.dylib; do
    fix_install_name "$prefix/lib/$library"
done

step "Check the libraries"
"$ENGINE_REPO/engines/scripts/check-unix-libs.sh" "$prefix"
rm -rf "$work"
