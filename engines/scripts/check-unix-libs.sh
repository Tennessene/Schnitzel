#!/bin/bash
#
# check-unix-libs.sh: checks the libraries built by build-unix-libs.sh.
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/check-unix-libs.sh DEPS_PREFIX
#
# Every library Wine loads by name must exist, be x86_64 only, target macOS 14 or older,
# carry its plain file name as install name (Wine dlopens it by that name), and link only to
# system libraries or, through @loader_path, to each other.

set -euo pipefail
prefix="${1:?usage: check-unix-libs.sh DEPS_PREFIX}"

# The names Wine dlopens or links (see RuntimeLibraries.required in SchnitzelKit).
required=(libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libinotify.0.dylib libgmp.10.dylib)
failed=0
fail() { echo "error: $*" >&2; failed=1; }

for name in "${required[@]}"; do
    library="$prefix/lib/$name"
    [[ -f "$library" ]] || { fail "$name is missing"; continue; }

    archs="$(lipo -archs "$library")"
    [[ "$archs" == "x86_64" ]] || fail "$name is built for '$archs', not x86_64"

    minos="$(otool -l "$library" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
    [[ -n "$minos" && "${minos%%.*}" -le 14 ]] || fail "$name requires macOS $minos (must be 14 or older)"

    id="$(otool -D "$library" | tail -1)"
    [[ "$id" == "$name" ]] || fail "$name has install name $id (expected $name)"

    while read -r dependency; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*) ;;
            @loader_path/*) [[ -f "$prefix/lib/${dependency#@loader_path/}" ]] || fail "$name needs $dependency, which isn't built" ;;
            *) fail "$name links to $dependency, outside the system and the build" ;;
        esac
    done < <(otool -L "$library" | tail -n +2 | awk '{print $1}' | grep -vx "$name")

    echo "ok      $name ($archs, macOS $minos+)"
done

# GnuTLS must not need libraries CrossOver doesn't ship.
if otool -L "$prefix/lib/libgnutls.30.dylib" | grep -qE 'nettle|hogweed|tasn1|unistring|p11-kit|idn'; then
    fail "libgnutls.30.dylib links to a library that should have been built in"
fi

exit $failed
