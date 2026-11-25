#!/bin/bash
#
# package-engine.sh: packages the built Wine and its libraries into the engine archive (M4).
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage: engines/scripts/package-engine.sh INPUTS_DIR OUTPUT_DIR VERSION
#   Needs OUTPUT_DIR/wine (build-wine.sh), OUTPUT_DIR/deps and OUTPUT_DIR/moltenvk.
#   VERSION is <CrossOver version>-<build>, for example 26.3.0-1.
#   Writes OUTPUT_DIR/dist/schnitzel-engine-VERSION.tar.xz and its .sha256 file.
#
# Layout of the archive (one top folder, named like the archive):
#   bin/              wine, wineserver and Wine's own programs (no developer tools)
#   lib/              FreeType, GnuTLS, GMP, SDL2, libinotify and MoltenVK
#   lib/wine/         Wine's unix and Windows-side modules (no import libraries)
#   share/wine/       wine.inf, NLS files and fonts
#   LICENSES/         every license that applies to what is in the archive
#   BUILDINFO.json    every input with its SHA-256, the commit, toolchain and runner
#   SOURCE.md         where the exact source of every part is (LGPL)
#   version           the engine version, read by Schnitzel

source "$(dirname "$0")/common.sh"

inputs="${1:?usage: package-engine.sh INPUTS_DIR OUTPUT_DIR VERSION}"
output="$(cd "${2:?usage: package-engine.sh INPUTS_DIR OUTPUT_DIR VERSION}" && pwd)"
version="${3:?usage: package-engine.sh INPUTS_DIR OUTPUT_DIR VERSION}"
inputs="$(cd "$inputs" && pwd)"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9A-Za-z.]+$ ]] || { echo "error: version '$version' isn't <CrossOver version>-<build>" >&2; exit 1; }
[[ "${version%%-*}" == "$(input_field crossover-sources version)" ]] \
    || { echo "error: version $version doesn't match the CrossOver drop $(input_field crossover-sources version)" >&2; exit 1; }

name="schnitzel-engine-$version"
wine="$output/wine"
deps="$output/deps"
moltenvk="$output/moltenvk"
for folder in "$wine/bin" "$wine/lib/wine" "$deps/lib" "$moltenvk/lib"; do
    [[ -d "$folder" ]] || { echo "error: $folder is missing; build first" >&2; exit 1; }
done
stage="$output/package/$name"
dist="$output/dist"
rm -rf "$output/package" "$dist"
mkdir -p "$stage" "$dist"

step "Copy Wine"
# cp -a keeps symlinks and permissions.
cp -a "$wine/bin" "$stage/bin"
mkdir -p "$stage/lib" "$stage/share"
cp -a "$wine/lib/wine" "$stage/lib/wine"
cp -a "$wine/share/wine" "$stage/share/wine"
# Developer tools and import libraries aren't needed to run programs.
for tool in function_grep.pl widl winebuild winecpp winedump wineg++ winegcc winemaker wmc wrc; do
    rm -f "$stage/bin/$tool"
done
find "$stage/lib/wine" -name '*.a' -delete

step "Copy the libraries"
# Only the shared libraries; headers, static archives and pkg-config files stay behind.
find "$deps/lib" "$moltenvk/lib" -maxdepth 1 -name '*.dylib' -exec cp -a {} "$stage/lib/" \;
ls -l "$stage/lib" | grep -v '^total'

step "Make the package self-contained and re-sign it"
python3 -I "$ENGINE_REPO/engines/scripts/macho.py" fix "$stage"

step "Licenses"
licenses="$stage/LICENSES"
mkdir -p "$licenses"
cp "$wine/COPYING.LIB" "$licenses/Wine-COPYING.LIB"
cp "$wine/LICENSE" "$licenses/Wine-LICENSE"
cp "$wine/AUTHORS" "$licenses/Wine-AUTHORS"
cp "$deps/licenses/"* "$licenses/"
cp "$moltenvk/licenses/"* "$licenses/"
# Wine's Windows-side modules are built with MinGW-w64 GCC and contain parts of its runtime
# (libgcc, under the GCC Runtime Library Exception; MinGW-w64 runtime pieces).
toolchain="$output/mingw-gcc-x86_64"
[[ -d "$toolchain/licenses" ]] || { echo "error: $toolchain/licenses is missing; build the toolchain first" >&2; exit 1; }
cp "$toolchain/licenses/"* "$licenses/"
ls "$licenses"

step "BUILDINFO.json and SOURCE.md"
commit="${GITHUB_SHA:-$(git -C "$ENGINE_REPO" rev-parse HEAD)}"
repository="${GITHUB_REPOSITORY:-Tennessene/Schnitzel}"
printf '%s\n' "$version" > "$stage/version"
python3 -I - "$ENGINE_INPUTS_JSON" "$stage" "$version" "$commit" "$repository" "$moltenvk/revisions.txt" "$wine/configure-args.txt" "$wine/wine-version.txt" "$wine/patches.txt" <<'PY'
import json, os, platform, subprocess, sys, datetime
inputs_json, stage, version, commit, repository, revisions, configure_args_file, wine_version_file, patches_file = sys.argv[1:]
patches = [line.split(" ") for line in open(patches_file).read().splitlines() if line.strip()]

def out(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True).stdout.strip().splitlines()[0]
    except Exception:
        return "unknown"

inputs = json.load(open(inputs_json))["inputs"]
used = [i for i in inputs if i["id"] not in ("dxmt", "dxmt-license")]
moltenvk_deps = [line.split(" ") for line in open(revisions).read().splitlines() if line.strip()]
configure_args = open(configure_args_file).read().split("\n")
configure_args = [a for a in configure_args if a]
info = {
    "schemaVersion": 1,
    "name": "Schnitzel engine",
    "version": version,
    "description": "Wine built from CodeWeavers' CrossOver source drop for Schnitzel",
    "wine": open(wine_version_file).read().strip().replace("Wine version ", ""),
    "repository": f"https://github.com/{repository}",
    "commit": commit,
    "buildScripts": f"https://github.com/{repository}/tree/{commit}/engines",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runner": {
        "image": os.environ.get("ImageOS", "local"),
        "imageVersion": os.environ.get("ImageVersion", "local"),
        "macOS": platform.mac_ver()[0],
        "machine": platform.machine(),
    },
    "toolchain": {
        "xcode": out("xcodebuild", "-version"),
        "clang": out("clang", "--version"),
        "windowsCompiler": "MinGW-w64 GCC " + next(i["version"] for i in inputs if i["id"] == "gcc")
            + ", binutils " + next(i["version"] for i in inputs if i["id"] == "binutils")
            + ", MinGW-w64 " + next(i["version"] for i in inputs if i["id"] == "mingw-w64"),
        "deploymentTarget": os.environ.get("MACOSX_DEPLOYMENT_TARGET"),
    },
    "architecture": "x86_64 (runs under Rosetta 2 on Apple Silicon); WoW64: 32-bit and 64-bit Windows programs",
    "features": {
        "msync": "compiled in; turned on with WINEMSYNC=1 for every Wine process and wineserver",
        "d3dmetalHooks": "Wine's side only; Apple's D3DMetal is never included",
        "gstreamer": False,
    },
    "configure": configure_args,
    "inputs": [{k: i[k] for k in ("id", "name", "version", "url", "sha256", "license")} for i in used],
    "fetchedDuringBuild": [
        {"component": "MoltenVK dependency " + d[0], "source": d[1], "commit": d[2]} for d in moltenvk_deps if len(d) == 3
    ],
    "patches": [
        {"file": p[0], "sha256": p[1], "source": f"https://github.com/{repository}/blob/{commit}/engines/patches/wine/{p[0]}"}
        for p in patches
    ],
}
json.dump(info, open(os.path.join(stage, "BUILDINFO.json"), "w"), indent=2)
open(os.path.join(stage, "BUILDINFO.json"), "a").write("\n")

cx = next(i for i in inputs if i["id"] == "crossover-sources")
lines = [
    f"# Source of Schnitzel engine {version}",
    "",
    "This engine is Wine built from CodeWeavers' Wine source (as published in the CrossOver",
    "source drop) by Schnitzel's open build scripts, with the Schnitzel patches listed below.",
    "",
    "## Build scripts",
    "",
    f"- {info['buildScripts']} (commit `{commit}`)",
    "",
    "## Sources, with SHA-256",
    "",
    "Every file below is also attached to the GitHub release this engine was published in,",
    "so the exact source stays available even if an upstream link changes.",
    "",
]
for i in used:
    lines.append(f"- **{i['name']} {i['version']}** ({i['license']}): {i['url']}")
    lines.append(f"  - SHA-256 `{i['sha256']}`")
    for p in i.get("provides", []):
        lines.append(f"  - `{p['path']}`: {p['component']} (upstream {p['upstreamVersion']})")
lines += ["", "## Schnitzel's patches to Wine", ""]
if not patches:
    lines.append("- none")
for p in patches:
    lines.append(f"- `{p[0]}` (SHA-256 `{p[1]}`): https://github.com/{repository}/blob/{commit}/engines/patches/wine/{p[0]}")
lines += ["", "## Fetched by MoltenVK's build (git commits)", ""]
for d in moltenvk_deps:
    if len(d) == 3:
        lines.append(f"- {d[0]}: {d[1]} at `{d[2]}`")
    elif len(d) >= 2:
        lines.append(f"- {d[0]}: CodeWeavers' copy in the CrossOver drop (revision `{d[-1]}`)")
lines.append("")
open(os.path.join(stage, "SOURCE.md"), "w").write("\n".join(lines))
PY
sed -n 1,40p "$stage/BUILDINFO.json"

step "Check the package"
"$ENGINE_REPO/engines/scripts/check-engine.sh" "$stage"

step "Archive"
archive="$dist/$name.tar.xz"
# Reproducible ordering and ownership; xz with all CPUs.
if command -v xz > /dev/null; then
    (cd "$output/package" && COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname wheel -cf - "$name" | xz -T0 -9 > "$archive")
else
    (cd "$output/package" && COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname wheel -cJf "$archive" "$name")
fi
(cd "$dist" && shasum -a 256 "$name.tar.xz" > "$name.tar.xz.sha256")
cat "$dist/$name.tar.xz.sha256"
size="$(du -h "$archive" | awk '{print $1}')"
echo "packaged $name ($size)"
summary "- Engine archive: \`$name.tar.xz\` ($size), SHA-256 \`$(awk '{print $1}' "$dist/$name.tar.xz.sha256")\`"
