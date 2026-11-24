# Handoff: own engine builds (November 24, 2026)

Read this first, then `SCHNITZEL_PLAN.md` ("Own engine builds", especially "Build plan" and the 11.0_1 lesson). Work on the branch `own-engine-builds`. Commits are SSH-signed under Anston's GitHub noreply address (already configured in global git config).

## Where we are

- Phases done and merged into `main`: Phase 1 (skeleton and rebrand) and the engine and Pfanne core. Anston tested both on Apple Silicon; Steam installs and runs in a Pfanne using Sikarugir's `WS12WineSikarugir10.0_8`.
- Current phase: **Own engine builds** (step 3 in the plan's order of work).
- **M1 is done and passed on GitHub Actions** (details below).
- **Anston's instruction for the next session:** work through **M2, M3, M4 and M5 in one go**, without stopping between milestones. Stop early only if:
  - a decision from Anston is needed;
  - something only Anston can do on GitHub is needed (a setting or permission);
  - the same problem is still stuck after a few solid attempts.

  Make sure each milestone's workflow actually passes on GitHub Actions before moving on. Stop at the end of M5, when there is a **draft** engine release that Schnitzel can download from the `schnitzel-engines` source. Then report to Anston in plain terms (what it means and what to decide first, then details), with exact test steps including creating a Pfanne with our engine and running Steam in it, and what to send back if something breaks.

## What exists on `own-engine-builds`

Committed and tested:
- `engines/inputs.json`: 9 inputs pinned by URL, version, license, size and SHA-256:
  - the CrossOver 26.3.0 drop (provides Wine, GnuTLS, MoltenVK, vkd3d and DXVK; see its `provides` list);
  - llvm-mingw 20261117 (macOS universal);
  - GMP 6.3.0, Nettle 3.10, FreeType 2.13.3, SDL2 2.32.10 and libinotify-kqueue 20240724;
  - DXMT v0.80 and its MIT license file.
- `engines/scripts/fetch.py` and `engines/tests/test_fetch.py` (12 tests): downloads with curl, https only, checks size and SHA-256, keeps valid files, deletes and fails on a mismatch, and checks `inputs.json` with `--check`. `--milestone M2` selects the inputs up to that milestone.
- `engines/test-programs/schnitzel-test.c` and `engines/scripts/check-toolchain.sh`: builds the test program as i686 (32-bit) and x86_64 (64-bit) Windows programs and checks their PE type. Each prints `schnitzel-test arch=<arch> bits=<32|64> wow64=<yes|no>` and exits with code 42. M4's prefix check must run both through Wine.
- `.github/workflows/engines.yml`, with these jobs:
  - `config`: the runner labels, in one place;
  - `validate`: on ubuntu;
  - `inputs`: on `macos-26-intel`, cached under `engine-inputs-${{ hashFiles('engines/inputs.json') }}`;
  - `toolchain`: uploads the `test-programs` artifact for 7 days.

  Actions are pinned to commit SHAs: checkout v7.0.1, cache v6.1.0, upload-artifact v7.0.2, and download-artifact v8.0.2 (`9000827ccba6bdab643e8b6fd33ac0654aef8333`, not used yet). The workflow has `permissions: contents: read`.

**WIP, committed as `069d136`. The scripts pass `bash -n`, but none has completed a run and none is in the workflow yet:**
- `engines/scripts/common.sh`: shared settings. x86_64 only (fails on arm64 unless run under `arch -x86_64`), `MACOSX_DEPLOYMENT_TARGET=14.0`, `-headerpad_max_install_names`, and helpers `input_field`, `input_archive`, `crossover_path`, `unpack`, `unpack_crossover`, `step` and `summary`.
- `engines/scripts/build-unix-libs.sh` (M2): builds into `OUTPUT/deps`:
  - GMP (shared);
  - Nettle (static, `-fPIC`);
  - CodeWeavers' GnuTLS (with its own libtasn1 and libunistring; no p11-kit, IDN, zlib, brotli or zstd);
  - FreeType (no png, harfbuzz, brotli or bzip2);
  - SDL2 (cmake);
  - libinotify-kqueue.

  It copies license files into `deps/licenses`. The local test under Rosetta was stopped during GMP; it was slow and it was running an older version of the script.
- `engines/scripts/check-unix-libs.sh`: the required libraries exist, are x86_64 only, require macOS 14 or older, have their plain file name as install name, and link only to the system or to each other via `@loader_path`. GnuTLS must not link to nettle, hogweed, tasn1, unistring, p11-kit or idn.
- `engines/scripts/build-moltenvk.sh` (M3, needs Xcode, so CI only):
  - moves CodeWeavers' `External/SPIRV-Cross` out of the way, because `fetchDependencies` deletes the folder before linking it;
  - runs `./fetchDependencies --macos --spirv-cross-root <that copy>`, then `make macos`;
  - thins the result to x86_64, names it `libMoltenVK.dylib`, and checks that it exports `vkGetInstanceProcAddr`.
- `engines/scripts/build-wine.sh` (M4):
  - unpacks llvm-mingw;
  - uses Homebrew's keg-only bison and flex;
  - configures CodeWeavers' Wine with `--enable-archs=i386,x86_64 --with-mingw` and the `--with`/`--without` list in the script (libunwind left on: macOS provides it);
  - fails unless `config.h` defines `SONAME_LIBFREETYPE`, `SONAME_LIBGNUTLS`, `SONAME_LIBVULKAN`, `SONAME_LIBSDL2` and `HAVE_SYS_INOTIFY_H`;
  - then runs `make` and `make install` into `OUTPUT/wine`.

## Exact next steps

1. **M2:** add a `unix-libs` job to `engines.yml` on the build runner. It restores the inputs cache with `fail-on-cache-miss`, runs `build-unix-libs.sh engines/.cache/inputs engines/build`, and caches `engines/build/deps` under a key hashing `inputs.json` and the scripts. Use the cache, not artifacts, to pass folders between jobs: upload-artifact drops symlinks and permissions. Push and fix until it passes. Expect fixes; the scripts are untested.
2. **M3:** add a `moltenvk` job the same way. Its output is `deps/lib/libMoltenVK.dylib`, and it must merge with the unix-libs output, so either cache the two separately and restore both, or have one job depend on the other.
3. **M4:**
   - Add a `wine` job: restore deps and MoltenVK, run `build-wine.sh`, cache `engines/build/wine`. Watch the 6-hour limit; split if needed.
   - Write `package-engine.sh`:
     - copy `wine/bin`, `wine/lib`, `wine/share` (drop include and man) and the `deps/lib` dylibs, keeping symlinks;
     - rewrite references so every Mach-O file links only to the system or `@loader_path/…` inside the package (for example `winebus.so` → `@loader_path/../../libinotify.0.dylib`);
     - remove build-path LC_RPATHs;
     - **re-sign every Mach-O ad hoc** (`codesign --force --sign -`), because install_name_tool breaks the linker signature;
     - add `LICENSES/` (Wine COPYING.LIB, LICENSE and AUTHORS, `deps/licenses/*`, llvm-mingw/MinGW runtime licenses), `BUILDINFO.json` (inputs and hashes, commit, toolchain versions, runner image) and `SOURCE.md`;
     - produce `schnitzel-engine-<version>.tar.xz` with a top folder of the same name and its SHA-256.
   - Write `check-engine.sh`:
     - the loader check: `lib/wine/x86_64-unix/wine` has `__PAGEZERO` 0x1000, `WINE_RESERVE` at 0x1000 and `WINE_TOP_DOWN` at 0x7ff000000000;
     - x86_64 only;
     - every Mach-O dependency resolves inside the package or to the system;
     - no `D3DMetal.framework` and no `libd3dshared.dylib`;
     - the **feature check**: `nm`/`strings` find the D3DMetal hooks in `winemac.so` (`d3dmetal`/`macdrv_d3dmtl…`), `CX_APPLEGPTK_LIBD3DSHARED_PATH` in `ntdll.so`, and MSync (`msync_init` …) in `ntdll.so` and `wineserver`.
   - Write `check-prefix.sh` and run it on `macos-26-intel` and on `macos-26` (install Rosetta there with `sudo softwareupdate --install-rosetta --agree-to-license`):
     - unpack the package and use the same environment as Schnitzel's `WineRuntime`: `WINEPREFIX`, `WINEDEBUG=fixme-all`, `PATH`, `DYLD_FALLBACK_LIBRARY_PATH=<engine>/lib:<engine>/lib/external:/usr/lib`, `WINEMSYNC=1`, `WINEESYNC=1`, and `WINEDLLOVERRIDES=mscoree,mshtml=` for wineboot only;
     - `wineboot --init` with a timeout, then `wineserver -w`;
     - require `drive_c`, `system.reg`, `user.reg`, at least 50 files in `system32`, and "msync: up and running" in the output;
     - `winecfg /v` prints the Windows version, `cmd /c echo ok` works, and `reg query` on a CurrentVersion value works;
     - **run both test programs** (32-bit and 64-bit; output and exit code 42 must match).
   - Also try the Rosetta fallback build once (the build on `macos-26` under `arch -x86_64`), as the plan says.
4. **M5:**
   - **Release job:** only for tags `engine-<CrossOver version>-<build>` (for example `engine-26.3.0-1`), and `needs` the package and both prefix checks. Give only this job `permissions: contents: write`. Create a **draft** release with `gh release create --draft`: the engine archive, `SHA256SUMS` and notes listing the inputs.
   - **In the app (SchnitzelKit `ComponentSource`):** add `schnitzelEngines` (repository `Tennessene/Schnitzel`, `tagPrefix: "engine-"`, `assetPattern: ^schnitzel-engine-(.+)\.tar\.xz$`, `versionPrefix: "schnitzel-engine"`), **not** the default.
   - **Drafts are invisible to the unauthenticated GitHub API and their files can't be downloaded without signing in.** So for Anston to test, he must publish the draft, as a **pre-release**. Make the `schnitzel-engines` source accept pre-releases (today `ReleaseCatalog.parse` skips them), and say this clearly in the report.
   - Detect engines that bring their own libraries (for example `lib/libgnutls.30.dylib` in the engine). New Pfannen with such an engine get no runtime-libraries pin, and the "no runtime libraries" warning must not show for them.
   - Add tests, update the plan, push, then tag `engine-26.3.0-1` and check that the draft appears.

## GitHub Actions state

- Run 45332254927 (push, commit `54ef4c8`): **success**, all four jobs, about 2 minutes.
- Run 45332504697 (manual): **success**; the inputs cache was restored and all 9 inputs re-verified.
- No run has used the WIP scripts yet, because they aren't in the workflow. The plan-only commits after `54ef4c8` didn't trigger runs (only `engines/**` and the workflow file do).

## Anston's decisions and requirements (all also in SCHNITZEL_PLAN.md now)

- **Releases are drafts;** Anston publishes them himself.
- **GStreamer comes later, in M7.**
- **DXMT comes from its own releases,** pinned with SHA-256, and its license is shipped.
- **Recommended rule:** Schnitzel's own engine does **not** replace Sikarugir 10.0_8 as Recommended until M7 (GStreamer) is done and Anston has tested it. Until then it's offered but not Recommended. `ComponentSource.defaultSourceIDs` stays on `sikarugir-engines`.
- **M4 prefix check runs a 32-bit and a 64-bit test program.**
- **M4 proves CodeWeavers' D3DMetal hooks and MSync are compiled in,** and the plan documents how MSync is turned on: `WINEMSYNC=1` for every Wine process and for wineserver. Schnitzel sets it in `PfanneSettings.environmentVariables` for the MSync setting (the default), plus `WINEESYNC=1` for D3DMetal.
- **llvm-mingw is pinned** with version and SHA-256 (done in M1).
- **Runner labels**, checked against GitHub's documentation in November 2026:
  - `macos-26-intel` is the build runner (Intel, 4 CPUs, 14 GB RAM, **14 GB disk**);
  - `macos-26` is Apple Silicon (3 CPUs, 7 GB RAM);
  - `macos-15-intel` is the fallback.

  The `-large`/`-xlarge` labels aren't free. The retirement policy is in the plan.
- **Jobs are split** with cached outputs so each stays under GitHub's 6-hour limit. At most 5 macOS jobs run at once, the cache holds 10 GB per repository, and entries are evicted after 7 days unused.
- **Ground rules:**
  - small commits, compile-check every step;
  - ask before big refactors or removing features;
  - no deadline: pick the most solid approach, not the fastest;
  - the UI stays in English with "Pfanne"/"Pfannen";
  - never bundle D3DMetal;
  - don't copy, decompile or redistribute closed CrossOver files (names and metadata only).

## Tried and didn't work (don't repeat)

- **Python's built-in HTTPS downloads:** they fail on Anston's Mac, because that Python has no certificate store (CERTIFICATE_VERIFY_FAILED). `fetch.py` uses curl for that reason.
- **Running Wine through system tools:** `perl`, `/usr/bin/env` when the variables are inherited, and other SIP-protected programs strip `DYLD_*` variables. Set `DYLD_FALLBACK_LIBRARY_PATH` inside the script, or pass it as an argument to `env`, then exec wine directly. A "Library not loaded … no LC_RPATH's found" error seen through `perl` was this, not a real problem.
- **`@rpath/` install names for Wine's runtime libraries:** Wine records whatever install name configure sees as the SONAME and dlopens that, so `@rpath/libgnutls…` wouldn't be found from `lib/wine/x86_64-unix`. Use plain names (`libgnutls.30.dylib`), found through `DYLD_FALLBACK_LIBRARY_PATH`, which Schnitzel sets to the engine's `lib`; the WIP scripts already do this.
- **The loader memory reserve is not why Sikarugir 11.0_1 fails;** its loader layout matches CrossOver's. The real cause is unknown. Don't spend time on it; the prefix check catches it.
- **Editing a bash script while it runs** breaks the run, because bash reads scripts as it goes.
- **Local builds under Rosetta are slow** (GMP alone took several minutes). Prefer CI for M2 and later, and test only small things locally.
- **`timeout`** doesn't exist on macOS; use a background process and a watchdog in bash.

## Watch out for

- **The runner's 14 GB disk:** the CrossOver drop unpacks to several GB. Unpack only the needed component (`unpack_crossover` does), and delete work folders.
- **MoltenVK's `fetchDependencies`** clones Vulkan-Headers, glslang, Vulkan-Tools, Volk and cereal from GitHub at the commits in the drop's `ExternalRevisions`, and uses `Templates/spirv-tools/build.zip`. Record these in BUILDINFO.
- **Wine's configure picks up llvm-mingw from `PATH`.** Check that the PE side really built for both i386 and x86_64 (both `lib/wine/i386-windows` and `x86_64-windows` exist).
- **Signatures:** after any `install_name_tool` change, re-sign, or the binaries get killed.
- **Rosetta on the arm runner:** `macos-26` may not have Rosetta preinstalled.
- **What CI can't test:** D3DMetal itself can't be tested in CI (never bundled); only the compiled-in support is checked.
- **Version names:** installed versions are `<source prefix>-<core>`; Schnitzel's engine will be `schnitzel-engine-26.3.0-1`.
- **Scratch folders:** the local scratch files from this session (inputs and a partial build under the old session's scratchpad) are deleted; re-fetch with `fetch.py` if needed.
