# Handoff: own engine builds (updated November 24, 2026)

Read this first, then `SCHNITZEL_PLAN.md` ("Own engine builds", especially "Build plan" and the 11.0_1 lesson). Work on the branch `own-engine-builds`. Commits are SSH-signed under Anston's GitHub noreply address (already configured in global git config).

## Where we are (updated during the session of November 24, 2026)

- Phases done and merged into `main`: Phase 1 (skeleton and rebrand) and the engine and Pfanne core. Anston tested both on Apple Silicon; Steam installs and runs in a Pfanne using Sikarugir's `WS12WineSikarugir10.0_8`.
- Current phase: **Own engine builds** (step 3 in the plan's order of work).
- **M1, M2 and M3 are done and passed on GitHub Actions.** M4 and M5 are written and in CI (see below).
- **Anston's instruction:** work through M2–M5 in one go; stop early only for a decision, a GitHub setting only Anston can change, or a problem still stuck after a few solid attempts. Every milestone's workflow must pass on GitHub Actions. Stop at the end of M5, when there is a **draft** engine release that Schnitzel can download from the `schnitzel-engines` source, then report in plain terms with exact test steps (including a Pfanne with our engine running Steam) and what to send back if something breaks.

## What exists on `own-engine-builds`

- `engines/inputs.json` (9 pinned inputs), `engines/scripts/fetch.py` with tests, the toolchain check and test programs (M1).
- `engines/scripts/common.sh`: x86_64 only, macOS 14 minimum, `-Werror=unguarded-availability(-new)` so a call to a macOS function newer than 14 fails the build.
- `build-unix-libs.sh` + `check-unix-libs.sh` (**M2, passing**): plain install names are set only at the end; libinotify gets `ac_cv_func_fdclosedir=no`.
- `build-moltenvk.sh` (**M3, passing**): output in `engines/build/moltenvk/{lib,licenses,revisions.txt}` (its own cache).
- `build-wine.sh` (M4): configure options in an array (saved to `configure-args.txt`), checks `SONAME_LIBVULKAN "libMoltenVK.dylib"`, `PE_ARCHS` has i386 and x86_64, and all of `lib/wine/{i386-windows,x86_64-windows,x86_64-unix}` installed. Saves `wine-version.txt`.
- `macho.py` (`list|fix|check`): rewrites every non-system link to `@loader_path/…` inside the package (plain names too), deletes build rpaths, re-signs everything ad hoc; `check` verifies x86_64-only, links, rpaths and signatures. Tested locally on a fake package.
- `package-engine.sh INPUTS OUTPUT VERSION` (M4): `schnitzel-engine-<version>/` with bin (no dev tools), lib (dylibs + MoltenVK), lib/wine (no `.a`), share/wine, LICENSES, BUILDINFO.json, SOURCE.md, version; runs check-engine.sh; writes `.tar.xz` and `.sha256` into `engines/build/dist`.
- `check-engine.sh` (M4): layout, loader segments (parser tested locally), `macho.py check`, no D3DMetal, CodeWeavers' features by strings (`macdrv_d3dmtl` in winemac.so; `CX_APPLEGPTK_LIBD3DSHARED_PATH`, `Server is running with WINEMSYNC`, `WINEMSYNC` in ntdll.so; `msync: up and running` in wineserver).
- `check-prefix.sh ARCHIVE TEST_PROGRAMS WORK` (M4): Schnitzel's environment via `env -i`, wineboot with a watchdog, prefix state, syswow64, MSync message, winecfg /v, cmd, reg query, both test programs (exit 42 and exact lines).
- `release-notes.py` (M5) and the workflow jobs `wine`, `package`, `check-prefix` (matrix Intel / Apple Silicon with Rosetta install) and `release` (only for `engine-*` tags; `contents: write` only there; `gh release create --draft --prerelease --verify-tag` with the engine, the exact source files and `SHA256SUMS`; re-runs refresh a draft, never a published release).
- **App side (M5, committed, 68 tests pass):** `ComponentSource.schnitzelEngines` (not the default), `includesPrereleases` (drafts never listed), `AvailableComponent.isPrerelease` shown as "Test build", `InstalledComponent.includesRuntimeLibraries` / `RuntimeLibraries.bundledInEngine`; new Pfannen with such an engine get no libraries pin; the warnings, the welcome screen and the run log account for it.

## Next steps

1. Get the `wine` job green (watch for configure tests that pick up too-new macOS functions: fix with `ac_cv_func_<name>=no`), then `package` and both `check-prefix` jobs.
2. Try the Rosetta fallback build once (plan).
3. Tag `engine-26.3.0-1`, push the tag, check the draft release appears with all files. Note: tag runs can't use the branch's caches, so the tag run builds everything from scratch (about 3 hours).
4. Build **Install from file…** as SCHNITZEL_PLAN.md describes under "In Schnitzel" (Anston's change, November 24, 2026), remove `--prerelease` from the release job, then update the plan (M4/M5 done) and report. Anston tests drafts privately with Install from file; he never publishes untested engines, not even as pre-releases.

## GitHub Actions state

- Runs 45335298469 and 45335820497: first M2/M3 attempts (fixed: GMP not loadable by Nettle's configure test; xcodebuild broken pipe; libinotify `fdclosedir`). M3 passed in 45335820497.
- Run 45339442700 (commit with the M4/M5 jobs): M2 passed; M3 rebuilding because `common.sh` changed; Wine next.

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
- **Plain install names (`libgnutls.30.dylib`, no "/"):** wrong, despite an earlier note here. Wine's configure keeps only what follows the last "/" (see `WINE_CHECK_SONAME` in `aclocal.m4`), so `@rpath/libgnutls.30.dylib` gives the right SONAME and a plain name gives garbage. Fixed; see the plan's M2 note.
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
