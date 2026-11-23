#!/bin/bash
#
# Runs Schnitzel's unit tests.
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# With full Xcode installed, plain `swift test` works. With only the Command Line Tools,
# the Swift Testing framework lives outside the default search path, so this script adds it.

set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
extra=()
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    libs="$developer_dir/Library/Developer/usr/lib"
    extra=(
        -Xswiftc -F -Xswiftc "$frameworks"
        -Xlinker -F -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$libs"
    )
fi

swift test "${extra[@]}" "$@"
