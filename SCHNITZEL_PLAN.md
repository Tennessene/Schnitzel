# Schnitzel — Project Plan

Schnitzel is a free, open-source Mac app for running Windows games, with an interface that is as easy to use as CrossOver's but has its own look. It is a **new SwiftUI app** that manages its own Pfannen and runs Wine directly. It builds on the work of Sikarugir, Kegworks and Wineskin, and reuses selected parts of **Whisky**'s WhiskyKit (GPL-3.0).

Schnitzel is a **standalone project**, not a GitHub fork: it lives at `github.com/Tennessene/schnitzel`. Early work began in a fork of Sikarugir's public landing repo (now `Tennessene/schnitzel-old`), which holds no app source code; its leftover files have been removed. Sikarugir's Creator.app and Launcher are closed source, so they couldn't be forked anyway (see Phase 0).

Tagline: *"Windows games, pounded flat for your Mac."*

Changes are made in small steps on feature branches, compile-checked and unit-tested, and tested on Apple Silicon before merging. There is no deadline: choose the approach that gives the best result, not the fastest one.

---

## Ground rules

- **Do not copy CrossOver.** No CrossOver code, logo, icons, colors, wording ("Runs Great", "Limited Functionality"), star graphics or pixel-exact layouts. Borrowing general UX patterns (sidebar, install catalog, per-container settings) is fine.
- **Reimplementing CrossOver's closed parts is allowed; copying them is not** (Anston, November 2026). Schnitzel may write its own versions of what CrossOver's closed launcher, compatibility database and helpers do, based on observed behavior (process arguments, environment variables, loaded files, a user's own bottle files) and on CodeWeavers' open source. Never open, decompile, copy or redistribute CrossOver's closed program files (the `wine` launcher script, `cxcompatdb.so`, `cxfixes.xml` and the like).
- **License: GPL-3.0.** Schnitzel as a whole is GPL-3.0 because it reuses Whisky code. Files copied from Whisky keep their original copyright headers plus a note describing Schnitzel's changes. Any code taken from Sikarugir's LGPL-2.1 Configure sources keeps its LGPL notices. Credit Sikarugir, Kegworks, Wineskin, Whisky, Wine and Gcenx in the README.
- **Never bundle D3DMetal.** Apple's license forbids redistributing it. Schnitzel detects a D3DMetal the user installed from Apple's Game Porting Toolkit and links to Apple's download page.
- **Native macOS look.** SwiftUI, system colors, SF Symbols, standard sidebar. Propose the approach before rewriting anything big.
- **Small steps.** One feature per branch, small commits, and each step must build and run before moving on. Ask before large refactors or deleting existing features.
- **Terminology:** a bottle/wrapper is a **Pfanne** (plural **Pfannen**) everywhere in the UI, e.g. "New Pfanne", "GTA V Pfanne". Internal code names can stay whatever is clearest.
- **This plan is the single source of truth.** `docs/HANDOFF.md` is only a temporary note for switching to a new Claude Code session: it is rewritten from scratch at each switch, and the new session deletes it once it has read it and confirmed this plan is up to date. If the handoff ever disagrees with this plan, the plan wins.

---

## Phase 0: Understand the repo (done)

Findings:
- The original fork held no app source code: only Sikarugir's README, issue templates and Apple's D3DMetal license PDFs (all since removed).
- Sikarugir's only open-source app code is Configure.app (Objective-C, LGPL-2.1, in `Sikarugir-App/Sikarugir-foss-sources`). Creator.app and the Sikarugir Launcher, which create wrappers and apply DLL overrides and env vars at launch, are closed source with no license.
- Whisky (`Whisky-App/Whisky`, GPL-3.0, archived) has clean Swift code for running Wine, registry access, exe parsing and bottle settings. Its Wine build (CrossOver 22.1.1 with D3DMetal bundled), its update servers (`data.getwhisky.app`) and its global `WINEDLLOVERRIDES` approach to DXVK are not reused.

Decision: build Schnitzel as a new app. Copy these WhiskyKit parts: process and logging helpers, exe (PE) parser, registry helpers, bottle settings model. Write everything else new.

---

## Architecture

- **Build:** a Swift package (`Package.swift`) with a `SchnitzelKit` library (core logic, no UI) and a `Schnitzel` app target (SwiftUI). A script (`scripts/build-app.sh`) builds it with `swift build` and wraps it into `Schnitzel.app`. Full Xcode is not required, so every step can be compile-checked.
- **Pfanne on disk:** a folder under `~/Library/Application Support/Schnitzel/Pfannen/<name>/` holding a `Pfanne.plist` (settings and pinned component versions) and the Wine prefix.
- **Components:** Wine engines, DXVK, MoltenVK and DXMT live versioned side by side under `~/Library/Application Support/Schnitzel/Components/<component>/<version>/`, so Pfannen can pin a version and roll back. D3DMetal is only detected from the user's own Game Porting Toolkit install, never bundled.
- **Graphics layers:** designed so Phase 6 per-game choices work. Wine's `DllOverrides` can only choose between a DLL's *builtin* version (shipped inside the engine) and its *native* version (a file in the prefix's `system32`), never between two files of the same kind. So each Pfanne has two slots:
  - **Builtin slot, one provider per Pfanne.** D3DMetal and DXMT both work by replacing Wine's own builtin `d3d11`/`dxgi` (and for D3DMetal `d3d12`), so only one of them can be active in a Pfanne. The one exception: programs with the `usesWineGraphics` program setting get Wine's own DLLs, which the assembly keeps in `lib/schnitzel-wine-graphics` (Wine patch 0002; the Rockstar Games Launcher by default, as CrossOver does). Schnitzel builds an *engine assembly* for each combination it needs: an APFS clone (copy-on-write, so almost no extra disk space) of the pinned engine with the provider's files laid over it. Assemblies are cached under `Components/Assemblies/` and rebuilt if missing. Without an overlay, the builtin slot is whatever the engine ships (normally WineD3D).
  - **Native slot: DXVK.** DXVK's DLLs are copied into the Pfanne's `system32` and `syswow64`.
  - **Auto** (the default) fills the builtin slot with D3DMetal if it's imported, otherwise WineD3D. **Never DXMT** (decided by Anston, November 25, 2026): the builtin slot applies to every program in the Pfanne, launchers included (apart from `usesWineGraphics` programs), and DXMT's d3d11 lacks `SwapDeviceContextState`, which stops the Rockstar Games Launcher (see "Rockstar Games Launcher with 26.3.0-3" under "Findings and reference"). DXMT is used only when chosen for a Pfanne, later per game through recipes.
  - **Choosing per game** means choosing native or builtin per DLL, which `AppDefaults\<game>.exe\DllOverrides` can do. So per game, a Pfanne offers its builtin provider or DXVK. `d3d9` has no Metal provider, so builtin `d3d9` is always WineD3D.
  - Schnitzel writes explicit Pfanne-wide `DllOverrides` for `d3d9`, `d3d10core`, `d3d11`, `d3d12` and `dxgi`, so nothing depends on Wine's default load order. It never sets a global `WINEDLLOVERRIDES` for those DLLs, because the env var would override the per-game registry entries.
- **Env vars** (MSync, ESync, Metal HUD, D3DMetal options) are set per Pfanne when Schnitzel launches Wine.

---

## Order of work

1. **Phase 1:** skeleton and rebrand.
2. **Phase 2:** engine and Pfanne core.
3. **Phase 3:** own engine builds.
4. **Phase 4:** new main interface.
5. **Phase 5:** game presets (the Install screen needs the recipe format).
6. **Phase 6:** per-game graphics auto-detection.
7. **Phase 7:** the rest of the component updater.

Each phase is its own branch (`phase-1-rebrand`, and so on) with small commits.

---

## Phase 1: Skeleton and rebrand

- New Swift package with `SchnitzelKit` and the `Schnitzel` app, plus the `.app` build script.
- App name, bundle ID (`io.github.tennessene.Schnitzel`, based on the GitHub repo since no domain is owned), window titles and About window all say Schnitzel.
- **Pfanne/Pfannen** in all user-facing text from the start.
- New placeholder app icon (original design; schnitzel/pan themed is fine).
- `LICENSE` (GPL-3.0) and a README: what Schnitzel is, how to build it, credits to Sikarugir/Kegworks/Wineskin/Whisky/Wine/Gcenx, license.

Status: done, merged into `main`.

## Phase 2: Engine and Pfanne core

- Copy the selected WhiskyKit files into `SchnitzelKit` with their headers and a change note.
- Download Wine engines into the versioned component store, checking each download against the SHA-256 digest GitHub publishes for it. Each Pfanne pins its engine. Switching keeps the previous version for one-click rollback.
  - **Engine sources.** Schnitzel's own engine, built from CodeWeavers' CrossOver source (see "Own engine builds"), becomes the default once a build passes testing. Until then, the **Sikarugir engines** built by Gcenx (`Sikarugir-App/Engines`, e.g. `WS12WineSikarugir11.0_1`) are used **only as a temporary testing and comparison reference**, not as Schnitzel's default. The official **WineHQ builds** by Gcenx (`Gcenx/macOS_Wine_builds`) can be installed for comparison but are **never the default**: upstream Wine lacks MSync and the Mac driver hooks D3DMetal needs.
  - If an engine archive contains Apple's D3DMetal, Schnitzel deletes it right after unpacking and uses only the user's own import, so Schnitzel never distributes D3DMetal.
- Import D3DMetal from the user's mounted Game Porting Toolkit disk image (its `redist/lib` folder) into `Components/D3DMetal/<version>/`. That copy stays on the user's Mac.
- Install DXVK (Gcenx's DXVK-macOS, for now) and DXMT (`3Shain/dxmt`, builtin build) into the component store.
- **Runtime libraries (temporary reference component).** Engines don't contain the shared libraries Wine loads at runtime (FreeType for fonts, GnuTLS for HTTPS, the Vulkan loader and MoltenVK, SDL2 for controllers, libinotify, and what they depend on). Until "Own engine builds" builds them, Schnitzel takes them from Sikarugir's `Template-1.0.27` release, checked against GitHub's SHA-256. Only those open-source libraries are kept; Sikarugir's launcher, its SDK, Apple's D3DMetal (the template contains it) and everything else in the download are deleted during install. The UI marks this component as a temporary reference.
- Component sources are generic: one default source per kind (`ComponentSource.defaultSourceIDs`) decides the "Recommended" label and what new Pfannen use; each installed component records its source; release lists are read across several pages, optionally filtered by tag prefix; installed versions are named `<source prefix>-<version>`, so two sources can never clash.
- Create a Pfanne (Wine prefix, default Windows 10 64-bit), run an `.exe` in it, open C: in Finder, write a log per run.
- **Run log limits (November 25, 2026):** a log is cut when it passes 64 MB: the header, a note and the newest 16 MB stay. Per Pfanne at most 50 logs and 512 MB; the oldest go when a new log starts (`LogLimits.standard`). Programs keep running when their log is cut: Wine and every program it starts write straight into the file and some keep it open for hours (Steam started by its installer wrote a 16.9 GB `SteamSetup.log` in Anston's `Test` Pfanne), so logs are opened append-only and `LogLimiter` shortens them from outside every 5 s; nothing is blocked, signalled or stopped. Size pruning never deletes logs touched in the last 15 minutes or logs from before the limits (they have no marker attribute). Limits only apply while Schnitzel is open. Tested with `cmd` printing nonstop through Wine: cut at 67.6 MB to the newest output, `cmd` kept running.
- Graphics layer setup per Pfanne as described under Architecture.
- A minimal working UI (list, create, run, open C:, engine and graphics choice) so each piece can be tested. Phase 4 replaces it with the real design.
- Checked with the real downloads (November 2026): `WS12WineSikarugir11.0_1` unpacks to `wswine.bundle/`, contains DXMT and no D3DMetal or MoltenVK, and loads its runtime libraries from outside the engine (hence the libraries component).

Status: done and merged into `main` (merge `a8d1f98`, November 2026). Built on branch `engine-pfanne-core`, with unit tests for everything that doesn't need a real Wine run, plus opt-in end-to-end tests with real engines. First test on Apple Silicon found that Sikarugir's `WS12WineSikarugir11.0_1` can't start Windows processes outside Sikarugir (Sikarugir-App/Sikarugir#295; Sikarugir's maintainer says its engines only run inside Sikarugir), so `WS12WineSikarugir10.0_8` (Wine 10) is the temporary reference instead. This is one more reason to build Schnitzel's own engine next.

## Phase 3: Own engine builds

Goal: Schnitzel's default engine is Wine compiled from CodeWeavers' CrossOver source drops (`codeweavers.com/crossover/source`), built in the open with GitHub Actions and published as Schnitzel engine releases.

What the source contains (checked with CrossOver 26.3.0, November 2026): `sources/wine` is Wine 11.0 plus CodeWeavers' changes (204 files changed and 17 added compared to WineHQ's Wine 11.0, 39 distinct `CW HACK` markers in 34 files). The main changes are MSync (`server/msync.c`, `ntdll/unix/msync.c`), the Mac driver hooks D3DMetal uses (`winemac.drv/d3dmetal*`), Mac driver and windowing fixes, wined3d using Vulkan for d3d10/11 on macOS, Rosetta and WoW64 fixes, and game-specific workarounds. The drop also contains the other components CrossOver builds.

Every component in the CrossOver 26.3.0 source drop, compared with the matching upstream release (November 2026):

| Component | Upstream version | Modified by CodeWeavers? | What changed | Use in Schnitzel's builds |
|---|---|---|---|---|
| Wine | 11.0 | **Yes, heavily** | See above | CodeWeavers' version |
| DXVK | 1.10.3 | **Yes** (36 files, about 470 lines added) | MoltenVK workarounds (no direct mapping, A8 format, swizzled textures), d3d9 and d3d11 fixes, extra config options (frame rate limits, vendor/device ID, memory limits, nvapi hack), game-specific fixes | CodeWeavers' 1.10.3, replacing Gcenx's DXVK-macOS. **Never DXVK 2.x**: it needs Vulkan features MoltenVK lacks |
| MoltenVK | 1.2.10 | **Yes** (44 files, about 1,300 lines added) | Geometry shader support, descriptor and buffer binding fixes, sync changes, extra config options, newer SPIRV-Cross | CodeWeavers' version |
| vkd3d | 1.18 plus later development changes | **Yes** | A newer development snapshot than the 1.18 release (about 5,200 lines), plus two MoltenVK workarounds (descriptor indexing, tessellation output) | CodeWeavers' version (DirectX 12 over Vulkan; D3DMetal stays the preferred DirectX 12 layer) |
| GnuTLS | 3.8.3 | **Yes, small** | Keeps the TLS ClientHello extension order stable within a session; an Android build fix | CodeWeavers' version |
| Nettle | 3.10 | No (git checkout instead of tarball) | None in code | Upstream 3.10 |
| GMP | 6.3.0 | Build files only | Docs left out of the build | Upstream 6.3.0 |
| FreeType | 2.13.3 | No (git checkout instead of tarball) | None in code | Upstream 2.13.3 |
| GLib | 2.78.0 | No | None | Upstream 2.78.0 (needed by GStreamer) |
| GStreamer | 1.24.4 | No | None | Upstream 1.24.4 (needed by winegstreamer for game videos) |
| cabextract | 1.9.1 | Build files only | None in code | Not part of the engine (Winetricks helper) |
| busybox | 1.26.2 | Small | Android build tweaks | Not needed on Mac |
| Ghostscript | 9.06 | Not compared | Printing to PDF on Linux | Not needed on Mac |
| makedep | Older copy of Wine's build tool | Differs from Wine 11.0's | Used for CrossOver's own tooling | Use Wine 11.0's own `tools/makedep` |
| po4a, pyxdg, htmltextview, android/java-iso-tools | 0.30, 0.6, n/a, n/a | n/a | CrossOver's Linux and Android interface and documentation tools | Not needed |

Not in the source drop: **DXMT** (CrossOver ships v0.72 per its changelog; DXMT is open source at `3Shain/dxmt` and is built from there) and **SDL2** and **libinotify** (open source, built from upstream).

What CrossOver.app itself contains (CrossOver 26.3.0.39832, inspected by file names, types and version metadata only):
- **Built from the source drop:** `wineloader`, `wineserver`, the Wine DLLs in `lib/wine`, vkd3d, and the libraries in `lib64` (FreeType, GnuTLS with Nettle linked in, GMP, GLib, GStreamer, SDL2, libinotify, MoltenVK).
- **Graphics layers kept in separate folders:** `lib/dxvk` (DXVK), `lib/dxmt` (DXMT, including `nvapi64`/`nvngx` for DLSS), `lib64/apple_gptk` (Apple's D3DMetal 3.0, which CodeWeavers is licensed to ship and Schnitzel is not). CrossOver chooses one per bottle when it starts Wine.
- **Closed-source CrossOver extras:**
  - Affect how games run: the `wine` launcher (a Perl script that sets up the environment and graphics layer before starting `wineloader`); `cxcompatdb.so` and `share/crossover/data/cxfixes.xml` (CrossOver's per-game settings database, "automatically enable settings on a per-game basis" in its changelog); `steamurlhelper`; `winewrapper` and `winelib`.
  - Interface and bottle management only: the CrossOver app, its Python and Sparkle frameworks, the `cx*` tools (`cxbottle`, `cxstart`, `cxmenu`, `cxassoc`, `cxinstallfonts`, `cxwget`, `cxkeepalive`, …), Perl modules, bottle templates and translations.
  - Stand-ins for Windows and Office helper programs (`ctfmon`, `findfast`, `mosearch`, `qttask`, `pstores`, `imjpmig`, `ddhelp`, `maildoff`, `mdm`, `autorun`, `assocscan`, `extract`, `cxdummy`).
  - `unrar` (freeware, not open source).
- **Schnitzel equivalents to build ourselves (open source):** the environment setup the `wine` launcher does (Schnitzel's `WineRuntime`), and a per-game settings database (Schnitzel's Phase 5 recipes). Two variables from the source drop are already used: `CX_APPLEGPTK_LIBD3DSHARED_PATH` (where D3DMetal's library is) and `CX_ACTIVE_GRAPHICS_BACKEND`.
- **Worth testing:** CrossOver keeps each graphics layer in its own folder instead of copying it into the engine. Wine's `WINEDLLPATH` can point at such a folder, which would be simpler than Schnitzel's engine assemblies; it is still one layer per Pfanne, because it's an environment variable.

Plan:
- An `engines/` folder in this repository with the build script and the GitHub Actions workflow. Builds run on GitHub's macOS runners, which are free for public repositories.
- Build CodeWeavers' modified versions wherever they differ from upstream (see the table): Wine, DXVK 1.10.3, MoltenVK, vkd3d and GnuTLS. Use upstream releases for the unmodified ones (FreeType, Nettle, GMP, GLib, GStreamer) and for DXMT, SDL2 and libinotify, which aren't in the drop. Never DXVK 2.x.
- These builds replace the temporary components: Schnitzel's engine replaces the Sikarugir engine, Schnitzel's library bundle replaces the libraries taken from Sikarugir's Template, and Schnitzel's DXVK build replaces Gcenx's DXVK-macOS.
- Steps: download a source drop and check its SHA-256 (CodeWeavers publishes no checksums, so the hash of the first download is recorded in the repository and later downloads must match it); install the toolchain (Xcode command line tools, MinGW-w64 GCC for the Windows-side DLLs (see "Toolchain"), bison, flex and the libraries Wine links against); configure a WoW64 build (`--enable-archs=i386,x86_64`) for x86_64, since Wine on Apple Silicon runs under Rosetta; build; package `bin/`, `lib/` and `share/` into a `.tar.xz` laid out like the other engines; publish it as a GitHub release of this repository with its SHA-256 in the release and in a checksum file.
- Each release records exactly which source drop, toolchain versions and Schnitzel patches went into it, so any build can be reproduced.
- Gcenx's public build scripts (`Gcenx/macports-wine`, `Gcenx/macOS_Wine_builds`) are a reference for configure flags and dependencies. They have no license file, so Schnitzel learns from them and credits them but doesn't copy their files.
- **Never bundle Apple's D3DMetal.** The build includes only Wine's own side of the D3DMetal hooks. A CI check fails the build if `D3DMetal.framework` or `libd3dshared.dylib` appears in the package. CrossOver's `CX_APPLEGPTK_LIBD3DSHARED_PATH` variable may let Schnitzel point Wine at the user's imported D3DMetal instead of copying it into an engine assembly; check this during the phase.
- Schnitzel lists these releases as a third engine source (`ComponentSource`). When a build passes testing on Apple Silicon, it becomes the recommended engine and the Sikarugir engines are dropped from the default list.

Build plan (written November 2026, before the build work starts):

*Where things live.* `engines/inputs.json` pins every input by URL and SHA-256: the CrossOver source drop, the upstream release tarballs, the MinGW-w64 GCC toolchain sources (binutils, GCC, MinGW-w64, MPFR, MPC) and the DXMT release. A build never downloads anything that isn't in that file. `engines/scripts/` holds one script per step (fetch, unix libraries, MoltenVK, Wine, PE components, package, checks), and `.github/workflows/engines.yml` runs them. The scripts also run on a Mac with Xcode, so a build can be reproduced outside GitHub.

*Build order.* Everything is built for x86_64 (Wine runs under Rosetta on Apple Silicon), with a minimum of macOS 14, into a staging folder:
1. **Fetch and verify.** Download every input and stop on any SHA-256 mismatch. The CrossOver drop's hash is recorded when it is first added to `inputs.json`.
2. **Toolchain.** MinGW-w64 GCC 13.2.0 with binutils 2.41 and MinGW-w64 v11.0.1, built from pinned sources by `build-toolchain.sh` (one job per architecture, cached), for every Windows-side file. These are the versions CrossOver 26.3's Wine records. Never llvm-mingw/Clang (see "Toolchain" below). From Homebrew: bison and flex (installed natively before the Wine build); later meson, ninja and glslang (M6). Xcode comes with the runner.
3. **Unix libraries.** Built from source, matching what CrossOver ships in `lib64`:
   - GMP 6.3.0 and Nettle 3.10 (upstream; Nettle linked into GnuTLS, as in CrossOver);
   - **GnuTLS 3.8.3, CodeWeavers' copy**, with its bundled libtasn1 and libunistring;
   - FreeType 2.13.3 (upstream);
   - SDL2 2.32.x (upstream);
   - libinotify-kqueue (upstream).
4. **MoltenVK: CodeWeavers' 1.2.10**, built with Xcode. CrossOver ships `libMoltenVK.dylib` without a separate Vulkan loader. That suggests its Wine loads MoltenVK directly; confirm from Wine's configure output and copy that setup.
5. **Wine: CodeWeavers' 11.0.**
   - Configure as a WoW64 build (`--enable-archs=i386,x86_64`) with the pinned MinGW-w64 GCC (passed as `i386_CC`/`x86_64_CC`) and the staging libraries, without X11, using CodeWeavers' own macOS loader flags.
   - `make install` into the staging folder.
   - Then the loader check (second-stage reserved segments, see the 11.0_1 lesson above).
6. **Windows-side components, with the same MinGW-w64 GCC (M6):**
   - **vkd3d: CodeWeavers' snapshot**, giving `libvkd3d-1.dll` and friends as CrossOver ships them;
   - **DXVK: CodeWeavers' 1.10.3**, giving `x64/` and `x32/` DLLs. Never DXVK 2.x.
7. **Package.** The engine archive `schnitzel-engine-<CrossOver version>-<build>.tar.xz` holds `bin/`, `lib/` (the dylibs), `lib/wine/`, `share/wine/`, `BUILDINFO.json` (every input and its hash, the commit, toolchain versions), `LICENSES/` and `SOURCE.md` (where every source is, for the LGPL). DXVK gets its own archive, so it stays a separate component in Schnitzel.
   - Package checks: no `D3DMetal.framework` or `libd3dshared.dylib` anywhere; every Mach-O file links only to system libraries or to files inside the package (`otool -L`).
8. **Prefix check.** The required check described above, on `macos-26-intel` and on `macos-26` (Apple Silicon with Rosetta).
9. **Publish.** Started by hand: run the Engines workflow on the branch with `release` set to `<CrossOver version>-<build>` (`gh workflow run engines.yml --ref <branch> -f release=26.3.0-1`). Not by pushing a tag: a tag's run can't read the branch's caches (GitHub shares only the run's own branch's and the default branch's caches), so it would rebuild everything; a run on the branch restores the libraries, MoltenVK and Wine in under a minute each. The release job runs only when steps 7 and 8 pass, and is the only job that may write to the repository.
   - The workflow creates a **draft** GitHub release with the engine archive, a `SHA256SUMS` file, the exact source files it was built from (for the LGPL) and notes listing the inputs. GitHub also publishes each file's SHA-256 digest. The DXVK archive joins it in M6.
   - The draft targets the build's commit; its tag `engine-<version>` is created only when the draft is published. If that tag already exists at another commit, the release job fails.
   - If a check fails or is cancelled, re-run only the failed jobs (`gh run rerun <id> --failed`): the built engine is reused.
   - The draft is a normal (not pre-release) draft. Anston tests it privately before anyone else can see it: signed in on GitHub, he downloads the engine archive and `SHA256SUMS` from the draft, installs the archive in Schnitzel with **Install from file…** (Components), and tests it on Apple Silicon. Only if it works does he publish the release by hand. Untested engines are never published, not even as pre-releases.
   - Other builds are numbered development builds (`<CrossOver version>-dev.<run number>`) and only produce workflow artifacts, kept for 7 days.

*Not built in the first release:*
- **GLib and GStreamer** (used by `winegstreamer` for some games' video playback) are a separate milestone, because GStreamer is a large build. Until then the engine is configured without GStreamer, and the release notes say so.
- **DXMT** keeps coming from DXMT's own releases (`3Shain/dxmt`, open source, built by its own CI; it isn't in the CrossOver drop and CrossOver ships the same project). Its release archive and its license file are pinned in `inputs.json` with SHA-256 checksums (v0.80, MIT), and its license goes into `LICENSES/` wherever DXMT is shipped. Building it ourselves needs its own LLVM toolchain and can follow later if needed.

*In Schnitzel.*
- Two new sources: `schnitzel-engines` (this repository, tag prefix `engine-`, version prefix `schnitzel-engine`) and `schnitzel-dxvk` (tag prefix `dxvk-`).
- Schnitzel's engine contains its own libraries, so Pfannen using it need no runtime-libraries component.
- `schnitzel-engines` may list GitHub pre-releases (labelled "Test build") in case one is ever published that way, but testing never depends on it: drafts are tested through Install from file.
- **Install from file…** in Components (for engines, and for the other downloadable kinds where it fits): picks a local archive and installs it through exactly the same path as a download (unpacking, D3DMetal removal, validation, version naming from the file name, e.g. `schnitzel-engine-26.3.0-1.tar.xz` → `schnitzel-engine-26.3.0-1`, and the "brings its own libraries" detection).
  - SHA-256: if a `SHA256SUMS` file is next to the archive, the archive is checked against it and refused on a mismatch (or if it isn't listed). Without one, Schnitzel shows the archive's SHA-256 and asks for confirmation before installing.
  - The component records that it was installed from a local file, with the original file name and SHA-256, and shows this in its notes.
  - When the same version later appears from the `schnitzel-engines` source (after the release is published) with the same SHA-256, Schnitzel recognizes it as the installed component instead of offering a duplicate; Pfannen pinned to it keep working. A different SHA-256 under the same version name is flagged, never silently replaced.
- **Rule: Schnitzel's own engine does not replace the temporary Sikarugir 10.0_8 engine as Recommended until M7 (GStreamer) is done and Anston has tested that release on Apple Silicon.** Until then the own engine is offered next to it but not marked Recommended. Only then does `ComponentSource.defaultSourceIDs` switch to it, and the Sikarugir engine and Template libraries stop being recommended.

*Milestones.* Each milestone gets small commits and a test before the next:
- **M1:** `inputs.json` (every input pinned by URL, version, license and SHA-256, **including the Windows-side toolchain**), the fetch-and-verify script with tests, and the workflow skeleton with caching. The workflow also checks the toolchain by building a tiny 32-bit and 64-bit Windows test program, which M4's prefix check reuses. *Done (November 2026), first with llvm-mingw; the toolchain was switched to MinGW-w64 GCC 13.2.0 on November 24, 2026 (see "Toolchain"), built by `build-toolchain.sh`.*
- **M2:** unix libraries. *Done (November 2026): GMP, Nettle, CodeWeavers' GnuTLS, FreeType, SDL2 and libinotify build on `macos-26-intel` in about 10 minutes, all x86_64 with a macOS 14 minimum, linked only to the system and each other. Lessons: the libraries get `@rpath/<file name>` install names, set only after everything is built (configure's test programs must still load them). Wine's configure records only the file name after the last "/" and dlopens it, found through `DYLD_FALLBACK_LIBRARY_PATH`; a name without any "/" makes it record the whole `otool` line instead, and libinotify must not use `fdclosedir()`, which the runner's newer SDK has but macOS before 26.4 doesn't. Every build now treats unguarded use of a macOS function newer than the deployment target as an error.*
- **M3:** MoltenVK. *Done (November 2026): CodeWeavers' MoltenVK 1.2.10 with their SPIRV-Cross builds with Xcode 26.6 in about 30 minutes. The commits of the dependencies its script fetches from GitHub are recorded in `revisions.txt` and the engine's BUILDINFO.json.*
- **M4:** Wine, packaging, loader check and prefix check (artifacts only). *Done (November 2026, run 45349504731): Wine builds on `macos-26-intel` in about 30 minutes; the package is 160 MB as `.tar.xz` (1.0 GB unpacked) and passes the package check (loader segments, links, signatures, no D3DMetal, MSync and D3DMetal hooks compiled in); the prefix check passes on Intel and on Apple Silicon under Rosetta 2 (792 files in system32, 838 in syswow64, MSync up, winecfg/cmd/reg and both test programs). Lessons: llvm-mingw's unprefixed `clang` must not come first in `PATH` (it can't build Mac code; llvm-mingw has since been replaced by GCC); Wine's build tools need build-time rpaths to the `@rpath` libraries, which packaging removes again; bison and flex are installed natively (Homebrew refuses to run under Rosetta). Possible later improvement: the Windows-side DLLs carry debug info (`-g`), which makes the engine larger than needed.* M4 also adds:
  - **32-bit and 64-bit programs.** The prefix check runs the 32-bit (i686) and the 64-bit (x86_64) test program built with the toolchain in M1. Each prints a fixed line and exits with a fixed code. The check passes only if both run through the WoW64 build and their output and exit codes match.
  - **CodeWeavers' features are compiled in.** The runner can't test D3DMetal itself (Schnitzel never bundles it), so the check proves the support is there:
    - `winemac.so` contains the D3DMetal hook symbols from `winemac.drv/d3dmetal.c` (for example `macdrv_d3dmtl…`, checked with `nm`);
    - `ntdll.so` contains the `CX_APPLEGPTK_LIBD3DSHARED_PATH` loader code;
    - `ntdll.so` and `wineserver` contain MSync (`msync_init` and friends from `ntdll/unix/msync.c` and `server/msync.c`, checked with `nm`).
    - At runtime, `wineboot` with `WINEMSYNC=1` must print `msync: up and running`, and the server must start its MSync Mach port.
    - A build missing any of these fails.
  - **How MSync is turned on:** it's off unless the environment variable `WINEMSYNC=1` is set for every Wine process and for `wineserver`. A Wine process that doesn't match the server's setting refuses to run (the "Server is running with WINEMSYNC" message). Schnitzel sets it in `PfanneSettings.environmentVariables` when a Pfanne's Sync setting is MSync, which is the default. `WineRuntime` passes the same environment to `wine` and `wineserver`. Schnitzel also sets `WINEESYNC=1` alongside it, because D3DMetal checks for ESync.
- **Toolchain switch to GCC (done, November 25, 2026, run 45531786564):** the pinned toolchain builds on `macos-26-intel` (i686 in 44 min, x86_64 in 56 min, then cached); Wine with GCC takes about 1 h 45 min (Clang: 43 min). The compiler check passes (1575 PE files: every compiled one "GCC: (GNU) 13.2.0", 34 = 17 modules × 2 architectures with no code, no GCC or MinGW runtime DLLs). The prefix check passes on both runners. The Steam check that ran in CI then (`check-steam.sh`, Intel 143 s, Apple Silicon 209 s) has been replaced by `check-programs.sh`, which runs on Anston's Mac (see "Program check" below). Fixes needed for GCC 13.2 on the macOS 26 SDK: no manuals (`MAKEINFO=true`, no Texinfo on the runners), `engines/patches/gcc/0001` (C++ headers before `safe-ctype.h`, GCC PR 111632, fixed the same way in 13.3; only changes how the compiler itself is compiled), `--disable-libcc1` (same clash, plugin not needed), and the MinGW runtime configured with `CC=<target>-gcc` (the exported `CC=clang` won over `--host`). ccache for the Wine build was added on November 25, 2026 (`SCHNITZEL_CCACHE=1` in CI; the first run with it fills the cache, later runs after a small patch only recompile what changed).
- **Program check (November 25, 2026):** `check-steam.sh` set up Wine by hand and passed while a Pfanne made by the app failed, because the app's default Pfanne ran from a DXMT assembly with DXVK in system32. It is replaced by `check-programs.sh`, which drives the app's own code through `schnitzel-cli` (a SchnitzelKit command-line target: Install from File, the default components with DXMT and DXVK downloaded as in Components, New Pfanne, Run; `SCHNITZEL_DATA_DIR` keeps its data separate). In a new default Pfanne it runs the Rockstar Games Launcher's silent install (passes when Social Club is set up), then Steam's installer and first start (passes when Steam connects to a Connection Manager), in the order users are told. **It runs on Anston's Mac, not in CI** (Anston's decision, November 25, 2026, until he says otherwise): on the GitHub runners the Rockstar installer quits within seconds without installing anything (no folder, no log), while it works every time on his Mac; the runners have no real GPU, a data-center network and a fresh unattended account. Steam passed there on both runners (109 s Intel, 184 s Apple Silicon). **Silent install, found November 25, 2026:** the Rockstar installer matches `/s` (silent) and `/f` (force) anywhere in its command line, but without `/f` it only stays silent when `HKLM\SOFTWARE\Rockstar Games\Launcher` already exists. So `/silent` alone showed the setup wizard on every fresh Pfanne ("Normal install mode" in `ProgramData/Rockstar Games/Launcher/installer_log.txt`), and the earlier passing Rockstar checks on Anston's Mac passed because he clicked through it. With `/silent /forceinstall` it installs without a window in about 5 s but doesn't start the launcher ("Run on close: FALSE"), so the check starts `Launcher.exe` itself, which then installs Social Club (50 s, WineD3D, nobody touching anything). The check now fails if the installer logs "Normal install mode". This is probably also why the installer "quit" on the GitHub runners (a wizard with no one and likely no usable window session), not yet confirmed there. Run it before releasing an engine or a change to Pfanne setup (usage in the script). The CI attempt still found a real bug: Schnitzel refused to create Pfannen on Intel Macs because Rosetta wasn't installed (fixed: only Apple Silicon needs it). CI keeps the builds, the package check and the prefix check; manual `engine-run=<run ID>` runs only the prefix check on an earlier run's engine (about 5 minutes), and damaged cache downloads are retried once before a rebuild.
- **M5:** draft releases, the `schnitzel-engines` source, engines with their own libraries, and **Install from file…** with SHA-256 checks and duplicate matching (see "In Schnitzel" above). Done when a release run has created a draft release whose engine installs through Install from file. *Done (November 2026): run #13 created the draft "Schnitzel engine 26.3.0-1" (engine 162 MB, SHA-256 `1af2e7fa…44f9`); its archive passed the SHA256SUMS check and installed through the real Install from file code (opt-in test `installsARealEngineArchive`, run with `SCHNITZEL_ENGINE_ARCHIVE=<path>`). 26.3.0-1 couldn't show Steam's window and 26.3.0-2 (Clang-built) kept Steam from signing in; both drafts are deleted. **Now (November 25, 2026):** the draft "Schnitzel engine 26.3.0-3" is GCC-built, passes CI (package, compiler and prefix checks) and has Wine patch 0001. Anston's tests: with WineD3D, Steam and the Rockstar Games Launcher work, and the program check passes untouched; with D3DMetal 3.0, Steam works but the Rockstar Games Launcher fails to initialize (see "Rockstar Games Launcher with D3DMetal 3.0" under "Findings and reference"). The fix needs Wine patch 0002, so the next draft is 26.3.0-4. Engine releases stay drafts; Sikarugir 10.0_8 stays Recommended until M7 is done and Anston has tested.*
- **M6:** vkd3d and DXVK.
- **M7:** GLib and GStreamer.
- **Future milestone, ARM64 engine (after the CrossOver 27 source drop):** Apple is limiting Rosetta 2 starting with macOS 28 (2027), and it's unclear whether Wine will still be allowed to use it. CodeWeavers has announced that CrossOver 27 will have an ARM64 build that runs without Rosetta. When the CrossOver 27 source drop is published, check how its ARM64 build works: which x86 emulator it uses for Windows code, and how graphics layers like D3DMetal, DXVK and DXMT work on ARM64. Then add an ARM64 engine build that follows it, the same way Schnitzel follows 26.3.0 now. Until then, stay on x86_64 with Rosetta.

*Runners* (checked against GitHub's documentation, November 2026; free and unlimited for public repositories):

| Label | Machine | Used for |
|---|---|---|
| `macos-26-intel` | Intel x86_64, 4 CPUs, 14 GB RAM, 14 GB disk (documented; the runner actually showed about 136 GB free in November 2026, but don't rely on it) | Building everything; the prefix check on Intel |
| `macos-26` (= `macos-latest`) | Apple Silicon (M1), 3 CPUs, 7 GB RAM, 14 GB disk | The prefix check on Apple Silicon with Rosetta |
| `macos-15-intel` | Intel x86_64, same size | Fallback build runner if `macos-26-intel` misbehaves |

The labels are set in one place at the top of the workflow.

When GitHub retires an image (it announces this months ahead in `actions/runner-images`; macOS 14 was retired on November 2, 2026):
- Switch to the next newer image of the same kind and run a full build and prefix check before the next release.
- If GitHub ever stops offering Intel macOS runners, build on Apple Silicon under Rosetta instead (`arch -x86_64` for the whole build). This is slower but produces the same x86_64 engine. Try it once so the fallback is known to work before it's needed: `gh workflow run engines.yml --ref <branch> -f rosetta=true`. *Not done yet: the first trial (run #11, November 2026) was cancelled to free runners for the release.*
- No retirement date has been announced for `macos-15-intel` or `macos-26-intel` yet.

*Time limits.* GitHub stops a job after 6 hours and allows at most 5 macOS jobs at once (free plan). A full Wine build on a 4-CPU Intel runner is expected to take about 1.5–3 hours, and the libraries, MoltenVK, vkd3d and DXVK together about another hour. So the build is split into separate jobs that each stay well under 6 hours:
- `inputs`
- `unix-libs`
- `moltenvk`
- `wine`
- `pe-components`
- `package`
- the two `check` jobs
- `release`

Each job passes its result to the next as a workflow artifact, and caches it by the hash of its inputs and scripts, so an unchanged step is skipped. If the Wine job alone ever comes close to 5 hours, it is split again (configure plus the unix side, then the Windows-side DLLs). The cache has a 10 GB limit per repository and drops entries unused for 7 days, so the large CrossOver drop is cached once and shared by every job. Disk space is the tighter limit (14 GB), so each job deletes build trees it no longer needs.

What could go wrong:
- **Build environment.** CrossOver's own build setup isn't in the source drop, so dependency versions, configure flags and the mingw toolchain have to be worked out. GitHub's macOS runners change their Xcode and SDK versions over time and can break builds; pin versions and cache the toolchain.
- **Build time and limits.** A full Wine build takes well over an hour; caching helps. Jobs are limited to 6 hours.
- **Missing pieces.** Some CrossOver features may depend on parts not in the drop, or behave differently outside CrossOver (several hacks read `CX_*` variables). Each needs checking.
- **Dependencies.** FreeType, GnuTLS (with Nettle and GMP), SDL2, libinotify, MoltenVK, the Vulkan loader, GLib and GStreamer have to be built and bundled, with their licenses included in the package. MoltenVK is built with Xcode, which the runners have but which is a separate build system.
- **Signing.** Without an Apple Developer ID, builds are ad-hoc signed and unnotarized. Schnitzel installs them itself, and Wine runs under Rosetta, so this is manageable, but it needs testing on a clean Mac.
- **Licensing.** Wine is LGPL-2.1, so every release must link to the exact source it was built from, including Schnitzel's patches. CodeWeavers' trademarks ("CrossOver") must not be used in Schnitzel's engine names; describe them as "built from CodeWeavers' Wine source".
- **Compatibility.** A first build may work worse than the Sikarugir engine. Compare the two with the same games before switching the default.
- **Rosetta 2 being limited.** Apple is limiting Rosetta 2 starting with macOS 28 (2027), and it's unclear whether Wine will still be allowed to use it. Every Schnitzel engine today is x86_64 and needs Rosetta on Apple Silicon. CodeWeavers has announced an ARM64 build for CrossOver 27 that runs without Rosetta; Schnitzel follows it when that source drop is published (see the ARM64 milestone above) and stays on x86_64 with Rosetta until then.

Lesson from Sikarugir's `WS12WineSikarugir11.0_1` (November 2026, Sikarugir-App/Sikarugir#295):
- **What happens:** run outside Sikarugir's app, the first Wine process starts, but every Windows process it starts afterwards (starting with `wineboot.exe`) exits at once with code 1 and no message, right after mapping its exe, `ntdll.dll` and `apisetschema.dll`. `wineboot` then reports `failed to start wineboot 1` and no prefix is created. `WS12WineSikarugir10.0_8` and CrossOver 26.3.0's own Wine work with the same environment. Sikarugir's maintainer closed the report saying the engines aren't meant to run outside Sikarugir.
- **The loader memory reserve is not the cause, despite what the report suspected.** Wine on macOS has to keep the low 8 GB of address space free for Windows code. It does that in a second-stage loader, `lib/wine/x86_64-unix/wine`, linked with `-pagezero_size 0x1000` and two reserved segments, `WINE_RESERVE` (0x1000, 8 GB) and `WINE_TOP_DOWN` (0x7ff000000000). The first-stage `bin/wine` (CrossOver: `bin/wineloader`) is a small launcher with a normal 4 GB `__PAGEZERO` that only starts the second stage. 11.0_1 has exactly this two-stage layout, segment for segment the same as CrossOver 26.3.0. 10.0_8 uses an older single-stage layout, where `bin/wine` itself carries the reserved segments. Starting the second stage directly doesn't help either (tried in #295). The real cause is something else in how Sikarugir built or patched 11.0_1, probably something its own launcher sets up; it couldn't be pinned down from outside.
- **What Schnitzel's build must do:**
  - Build the loader exactly as CrossOver's `configure.ac` does on macOS x86_64: `bin/wine` as the first-stage launcher, and `lib/wine/x86_64-unix/wine` with `-pagezero_size,0x1000`, `-image_base,0x200000000`, `-segaddr,WINE_RESERVE,0x1000` and `-segaddr,WINE_TOP_DOWN,0x7ff000000000`.
  - Check the result with `otool -l`: the second stage must have both segments at those addresses and a 0x1000 `__PAGEZERO`. Fail the build if not.
  - Don't depend on anything from a launcher. Every variable Schnitzel's `WineRuntime` sets must be documented, and the engine must work with nothing else.
  - Above all, prove it works end to end before release with the prefix check below. That check would have caught 11.0_1, since `wineboot` can't fill system32 when child processes can't start.

Required check before any engine release is published:
- The GitHub Actions workflow creates a fresh prefix with the packaged engine, exactly as Schnitzel does: unpack the release archive, set the same environment, run `wine wineboot --init`, then `wineserver -w`.
- It then confirms the same three things Schnitzel checks after setup (`Pfanne.prefixState`): `drive_c` exists, `system.reg` and `user.reg` exist, and `drive_c/windows/system32` holds a real set of files (at least 50; a working prefix has several hundred).
- It also runs `wine winecfg /v` (must print the Windows version), `wine cmd /c echo ok` (a Windows process starting another one), and `wine reg query` on a key `wineboot` writes.
- It runs on an Intel runner and on an Apple Silicon runner with Rosetta, because Schnitzel's users are on Apple Silicon.
- The release job depends on these checks. A build that fails any of them is never published; it stays a workflow artifact for debugging.

## Phase 4: New main interface

- **Sidebar:** list of Pfannen, plus "Install" at the bottom.
- **Pfanne detail view:** installed programs/games with launch buttons, and a settings section:
  - Windows version (default Windows 10 64-bit)
  - Graphics: Auto / D3DMetal / DXMT / DXVK / WineD3D
  - Sync: MSync / ESync / off
  - Toggles: DLSS, High Resolution Mode
  - Wine engine version (pinnable)
- **Install screen:** search box, a list of presets (Phase 5) with Schnitzel's own rating labels, and "Install something not listed" (pick an .exe or installer).
- "Run command / open .exe in this Pfanne", "Open C: drive in Finder", "Winetricks".

## Phase 5: Game presets (recipe files)

- A simple, documented recipe format (JSON or YAML), one file per game or launcher, in a `recipes/` folder so the community can add more by pull request.
- Each recipe has: name, rating, Windows version, graphics layer, sync, toggles, dependencies (Winetricks verbs), launcher(s) to install, notes shown to the user, and the date and component versions it was tested with.
- First recipes:
  - **GTA V Legacy (Steam):** Windows 10 64-bit; graphics D3DMetal; MSync on; DLSS off; High Resolution Mode off; install Rockstar Games Launcher **and** Steam in the **same Pfanne**; note: in the Rockstar Launcher go to Settings → GTA V and disable BattlEye (story mode only, GTA Online does not work); install "Grand Theft Auto V Legacy", not Enhanced (Enhanced currently needs a DirectX 12 feature D3DMetal lacks).
  - **Halo: The Master Chief Collection (Steam):** Windows 10 64-bit; graphics D3DMetal (fallback DXVK); choose "Play with anti-cheat disabled" at launch (campaign and offline only).
  - **Steam** and **Rockstar Games Launcher** as standalone launcher recipes.

The CrossOver observations, the Steam and Rockstar Games Launcher investigations, the toolchain, what didn't work, `ROSETTA_ADVERTISE_AVX` and the program settings the recipes build on are under "Findings and reference".

## Phase 6: Per-game graphics auto-detection

Goal: one Pfanne holds a whole Steam library, and each game automatically gets the right graphics layer.

1. Scan the Pfanne's drive (e.g. `Program Files (x86)/Steam/steamapps/common/*`) for game `.exe` files.
2. Parse each exe's PE import table and see which of these it loads: `d3d12.dll`, `d3d11.dll`, `d3d10*.dll`, `d3d9.dll`.
3. Choose (per game, between the Pfanne's builtin provider and DXVK; see Architecture):
   - d3d12 → builtin, which must be D3DMetal
   - d3d11 → builtin when the Pfanne's provider is D3DMetal or a DXMT the user (or a recipe) chose, otherwise DXVK
   - d3d9/d3d10 → DXVK
   - D3DMetal and DXMT can't be mixed per game inside one Pfanne. The provider follows Auto (see Architecture): D3DMetal when it's imported, otherwise WineD3D; never DXMT unless chosen.
   - Recipes must never set DXMT for a Pfanne that has the Rockstar Games Launcher: DXMT v0.80's d3d11 lacks `SwapDeviceContextState`, which the launcher needs (source checked November 25, 2026: `3Shain/dxmt` main, `src/d3d11/d3d11_context_impl.cpp` line 1850, `UNIMPLEMENTED("SwapDeviceContextState")`). The launcher's `usesWineGraphics` setting (Wine patch 0002) may make DXMT Pfannen work too, but that hasn't been tested with DXMT, so the rule stays until it is.
4. Write **per-app DLL overrides** into the Pfanne's registry under `HKCU\Software\Wine\AppDefaults\<game>.exe\DllOverrides`, so Wine loads the right DLLs when Steam launches that game.
5. Show the detected choice for each game in the UI, with a manual override and a "Reset to auto" button.
6. Settings that are env vars (some D3DMetal options, MSync, and similar) can't be set per game through the registry. Phase 6 applies them per Pfanne. Note any that need a per-game launch shim later.
7. Rescan when the Pfanne opens and on demand.

## Phase 7: Component updater

Engine downloads, pinning and rollback come in Phase 2 (engine and Pfanne core). Phase 7 adds the updater UI for every component.

Show the installed version and the latest available version of each component, with update buttons:

| Component | Source | Auto-update? |
|---|---|---|
| Wine engine | Schnitzel's own builds from CodeWeavers' source (default once tested). Sikarugir engines as a temporary reference, WineHQ builds for comparison only (GitHub releases) | Yes |
| DXVK | Schnitzel's build of CodeWeavers' DXVK 1.10.3 (Gcenx's DXVK-macOS until then). Never DXVK 2.x | Yes |
| MoltenVK | Schnitzel's build of CodeWeavers' MoltenVK (taken from Sikarugir's Template until then) | Yes |
| DXMT | `3Shain/dxmt` GitHub releases, builtin build (v0.80, pinned now, is MIT; v0.81 and later are LGPL-2.1: when Schnitzel offers one, link its exact source and add its license to `LICENSES/`) | Yes |
| D3DMetal | Apple Game Porting Toolkit | **No.** Detect the installed version and link to Apple's download page; requires the user's free Apple ID |

Rules:
- **Never auto-update a working Pfanne.** Each Pfanne can pin its component versions. Updates go to new or unpinned Pfannen, or happen when the user chooses.
- Keep the previous version on disk so the user can roll back with one click.

---

## Findings and reference

What earlier phases found out, kept for reference: observations of CrossOver, program investigations, the toolchain and what didn't work. Everything here is evidence for decisions made elsewhere in the plan.

### What CrossOver does for Steam and GTA V Legacy (observed November 2026)

Read-only observation of Anston's CrossOver 26.3.0 bottle "GTA V" (template `win10_64`, D3DMetal on, MSync on, DLSS off, High Resolution Mode off) while Steam and GTA V Legacy ran: process arguments, the environment of CrossOver's wineserver, files mapped by the processes, and the bottle's own `cxbottle.conf`, `user.reg` and `system.reg`. Recipes should build on this.

**Steam.** Steam's interface is a Chromium browser, `steamwebhelper.exe`. On Wine for macOS it only shows its window when it runs **without the sandbox, with its GPU part in the same process and drawing in software**.
- CrossOver starts `steam.exe` with no options. Every running `steamwebhelper.exe` nevertheless has `--no-sandbox --in-process-gpu --disable-gpu` (plus `--use-angle=swiftshader-webgl` and `--disable-gpu-compositing`, which Steam adds itself). CrossOver adds the options while the process is created, through its closed `cxcompatdb.so` (loaded into every process by CW Hack 24067 in `ntdll/unix/loader.c`). CodeWeavers' 26.3 source no longer contains these per-program lists. Older drops did (Sikarugir's 10.0_8 engine still has them in `kernelbase`, with a `CommandLineAppend` registry value), which is why Steam worked with that engine.
- Without the options (Schnitzel engine 26.3.0-1), Steam's window stays invisible under DXMT ("cross-process swapchain not supported"), and is black under WineD3D (Vulkan or OpenGL) and even in software mode with the sandbox on. Steam's own launch options only cover part of it: `-no-cef-sandbox` and `-cef-disable-gpu` work, but there's no option for `--in-process-gpu`.
- **Schnitzel's version:** Wine patch 0001 (`engines/patches/wine`) makes `CreateProcessInternalW` append `HKCU\Software\Wine\AppDefaults\<program>\CommandLineAppend`. `ProgramDefaults.builtIn` in SchnitzelKit gives every Pfanne the Steam entry, and Pfanne setup writes it (see "Program settings" below).
- Not the cause, checked and ruled out: CrossOver's environment variables (recreated with Schnitzel's engine: no change), the Windows user name (CodeWeavers' Wine always reports `crossover` unless `CX_REPORT_REAL_USERNAME` is set), the bottle registry (only template defaults), and how the GPU is reported to Steam (identical).

**GTA V Legacy.** Launched from Steam: `PlayGTAV.exe -nobattleye` → Rockstar `Launcher.exe -skipPatcherCheck -steamAppId=271590 … -nobattleye` → `GTA5.exe … -nobattleye -enableCrashpad -useSteam -steamAppId=271590`, plus `RockstarService.exe`, `RockstarErrorHandler.exe` (Crashpad), Steam's `gameoverlayui64.exe` and several `SocialClubHelper.exe`.
- **Graphics:** `GTA5.exe` uses D3DMetal. Its `d3d11.dll`, `d3d12.dll`, `dxgi.dll` and `nvapi64.dll` load from a separate folder, `lib64/apple_gptk/wine/x86_64-windows`, which CrossOver puts in front of Wine's own DLLs. They aren't copied into the engine. Apple's `D3DMetal.framework`, `libd3dshared.dylib` and `libMoltenVK.dylib` load from next to it (`CX_APPLEGPTK_LIBD3DSHARED_PATH`). The bottle's registry has no DLL overrides for the game, so D3DMetal is used as the *builtin* d3d11/d3d12/dxgi, as Schnitzel's assemblies do. It confirms that the DLL-search-path approach ("Worth testing" under "Own engine builds") works: it could replace engine assemblies later. Also loaded: the game's own `d3dcompiler_43.dll` and `d3dx9_43.dll` (native, in system32, from its DirectX installer) and Social Club's `SocialClubD3D12Renderer.dll`.
- **Social Club:** every `SocialClubHelper.exe` runs with `--in-process-gpu --use-gl=angle --use-angle=swiftshader` (and `--no-sandbox`). The same per-program mechanism as Steam; it's in `ProgramDefaults.builtIn` too, not yet tested in Schnitzel.
- **Environment** (CrossOver's wineserver, relevant parts): `WINEMSYNC=1`, `CX_APPLEGPTK_LIBD3DSHARED_PATH`, `ROSETTA_ADVERTISE_AVX=1` (Rosetta reports AVX to the game; check whether GTA V or other games need it), `WINEDLLPATH` with the engine's `lib/wine` folders, `DOTNET_EnableWriteXorExecute=0`, `WINEDEBUG=-all`, and CrossOver's own `CX_ROOT`, `CX_BOTTLE…` variables (they only affect icons, printing and usage logging). The bottle's `cxbottle.conf` only adds `WINEMSYNC=1`.
- **Bottle registry:** standard `win10_64` template defaults (a list of `native, builtin` DllOverrides for old Microsoft components, `Direct3D\cb_access_map_w=1`, `Mac Driver\AllowSetGamma=0`); nothing specific to the game.
- **For the recipe:** D3DMetal, MSync, `-nobattleye` (BattlEye off in the Rockstar Launcher), Steam and the Rockstar Games Launcher in the same Pfanne, and the Social Club program setting. Older engines also had a "simulate write-copy" list in `ntdll` naming the Rockstar Launcher, SocialClubHelper, Steam's overlay and other launchers; CodeWeavers' 26.3 source only keeps `WINE_SIMULATE_WRITECOPY` as an environment variable. Check whether the Rockstar Launcher needs it in Schnitzel before adding it.

### Program investigations

**Steam sign-in and the Rockstar Games Launcher with 26.3.0-2: caused by the compiler (found November 24, 2026).** With 26.3.0-2, Steam's window shows but it never contacts its login servers (it keeps rescheduling "EConnect"), and the Rockstar Games Launcher fails ("Launcher has no default branch!", Social Club never installs, then error 00000010).
- Compared in scratch prefixes with identical files: CrossOver's own Wine signs Steam in within 9–36 s, ours never. Neither MSync on or off nor CrossOver's environment variables make a difference. Also ruled out: GnuTLS and certificates (HTTPS through WinHTTP works, 161 root certificates in every prefix), the clock, vkd3d, configure options, the Mac-side modules, and CrossOver's per-program database.
- A bisection over the 68 Wine DLLs `steam.exe` loads (CrossOver's version symlinked into a scratch copy of our engine, nothing copied into the repository) points to exactly one: **`kernelbase.dll`**. Our `kernelbase.dll` without patch 0001 fails too, so the patch isn't the cause.
- CrossOver builds every Windows-side Wine DLL with **MinGW-w64 GCC 13.2** ("GCC: (GNU) 13.2.0" in each), we use llvm-mingw (Clang). **Our own source with patch 0001, with only `kernelbase.dll` compiled by MinGW GCC (16.2 from Homebrew), fixes both:** Steam reaches its login servers (twice, 24 and 36 s), and the Rockstar Games Launcher installs Social Club 2.4.0.302 and starts its interface. The Clang build fails both every time. So CodeWeavers' Wine source depends on something only GCC does, somewhere in `kernelbase`; it isn't missing CodeWeavers code.
- Decision (Anston, November 24, 2026): build the whole Windows side with MinGW-w64 GCC like CrossOver; see "Toolchain".

**Rockstar Games Launcher with 26.3.0-3: caused by DXMT (found November 25, 2026).** In a new Pfanne with the GCC-built 26.3.0-3, the Rockstar Games Launcher still failed (error 00000010, no Social Club), and Steam's window disappeared after its first update.
- The Pfanne differed from the CI check and the earlier scratch tests in one big way: graphics Auto chose DXMT (no D3DMetal imported), so Schnitzel ran it from an engine assembly with DXMT's `d3d10core`, `d3d11`, `dxgi`, `winemetal`, `nvapi64` and `nvngx`, plus `CX_ACTIVE_GRAPHICS_BACKEND=dxmt`. CrossOver runs Anston's bottle with D3DMetal for every process.
- Reproduced in APFS clones of Anston's Pfanne with Schnitzel's exact launch (environment from its run log, the exe's folder as working directory, `wine <exe>`), then one change at a time on the plain engine: DXMT's d3d11/dxgi/d3d10core/winemetal fail 3 of 3 runs, each stopping at DXMT's log line `SwapDeviceContextState` (unimplemented, also in DXMT's newest source). DXMT's `nvapi64`/`nvngx` alone and the variable alone work. On fresh Pfannen made through the app's code, in Anston's order: DXMT fails, WineD3D sets up Social Club in about 100 s.
- With WineD3D the launcher hung once in 7 runs (its main thread waiting on a lock, `RtlpWaitForCriticalSection`); rare, still to watch.
- Steam never failed in 7 tests: copies of Anston's Pfanne (DXMT and WineD3D), fresh Pfannen through its whole first run, and after the Rockstar Games Launcher with its processes still running. The disappearing window was a single crash ("nested exception on signal stack") when Steam restarted after its first update; starting Steam again works. The program check runs Steam's first start on every build to catch it if it recurs.
- Fix: Auto never picks DXMT (see Architecture). Side finding: Wine can't load DLLs whose full path is longer than 260 characters; Schnitzel's own paths are far shorter (about 180 characters for Anston), but a very long user name or data folder could reach it.

**Rockstar Games Launcher with D3DMetal 3.0: "failed to initialize" (cause found and fix written, November 25, 2026; waiting for engine 26.3.0-4).** With D3DMetal 3.0 imported, a new default Pfanne (Auto → D3DMetal, DLSS off) installs and signs in Steam, but the Rockstar Games Launcher shows "The Rockstar Games Launcher failed to initialize!". CrossOver runs the same launcher with D3DMetal 3.0 in every process.
- Fails every time: Anston's Pfannen `test4` and `test-d3d`, and 2 of 2 fresh Pfannen made through `schnitzel-cli` (`check-programs.sh` with `D3DMETAL=`). The WineD3D control passes untouched (Social Club after 50 s, see the silent-install note under Program check).
- The launcher's own log (`Documents/Rockstar Games/Launcher/launcher.log`): it reaches "Initializing group 1", connects to its background service, but its worker thread (`[Workr]` lines) never starts; about 9 s later it stops the service and exits with code 1. Working first starts have about 40 worker lines (self-update, Social Club install).
- **Cause, proven (November 25, 2026):** the launcher creates a Direct2D factory (Wine's own `d2d1`) and asks it for a DC render target. Wine's `d2d1` needs a Direct3D 10.1 device for that and calls `D3D10CreateDevice1` → `D3D10CoreCreateDevice` (Wine's `d3d10_1`/`d3d10core`) → `dxgi.DXGID3D10CreateDevice`. In D3DMetal 3.0's `dxgi.dll` that export is a stub that prints its own signature with `puts` and returns `E_FAIL` (0x80004005); `DXGID3D10RegisterLayers` and `DXGIGetDebugInterface1` are stubs the same way. Trace (`+d2d,+d3d10,+d3d10core`): `d2d_factory_CreateDCRenderTarget` → `D3D10CoreCreateDevice ... Failed to create device, hr 0x80004005` → `d2d_factory_get_device Failed`, then the launcher gives up. D3DMetal's own `d3d10.dll` only exports `D3D10CreateDevice` and `D3D10CreateBlob`, not `D3D10CreateDevice1`. CodeWeavers' open Wine source has no change in `d2d1`, `d3d10_1`, `d3d10core`, `d3d11` or `dxgi`, so the difference is in which files CrossOver loads.
- **What CrossOver does (observed November 25, 2026, Anston's "GTA V" bottle, CrossOver 26.3, launcher started with CrossOver's `bin/wine --bottle`, `lsof` on the running processes, nothing of CrossOver's opened):** it chooses per program. `Launcher.exe` loads Wine's own `dxgi.dll`, `d3d11.dll`, `d3d10core.dll`, `d3d10_1.dll`, `d2d1.dll` and `wined3d.dll` from `lib/wine/x86_64-windows` (plus `libd3dshared.dylib` and MoltenVK), so its Direct2D works on WineD3D. The main `SocialClubHelper.exe` loads D3DMetal's `dxgi.dll` from `lib64/apple_gptk/wine/x86_64-windows` and `D3DMetal.framework`. CrossOver keeps D3DMetal's DLLs in that separate folder (d3d11, d3d12, dxgi, nvapi64, nvngx, atidxx64; no d3d10) instead of replacing Wine's. The open source shows CrossOver special-cases this launcher by path elsewhere too (CW HACK 23741 in `ntdll/unix/process.c`, alternative loader suppressed for `\Rockstar Games\Launcher\Launcher.exe`); the per-program D3DMetal choice itself isn't in the open source.
- **Fix (Anston chose the side-folder option, November 25, 2026; awaiting engine 26.3.0-4 and his test):** engine assemblies keep Wine's own copies of every file D3DMetal or DXMT replaces in `lib/schnitzel-wine-graphics/<arch>/` (assembly marker version 2; older assemblies are rebuilt). Wine patch 0002 (`ntdll`): if the main program's Windows path ends with an entry of `SCHNITZEL_WINE_GRAPHICS_PROGRAMS`, the folder in `SCHNITZEL_WINE_GRAPHICS_DLLPATH` is searched first for builtin DLLs, through CodeWeavers' `prepend_dll_path()` (the hook CrossOver's closed `cxcompatdb.so` uses). The program setting `usesWineGraphics` (with `pathEnding` for generic names) is on by default for `Rockstar Games\Launcher\Launcher.exe`; every other process, Social Club and GTA V included, keeps D3DMetal. The alternative, CrossOver's layout (no assemblies, D3DMetal in its own folder in front), was not chosen because it is a bigger refactor for the same result.
- **Tested with a temporary engine (November 25, 2026):** 26.3.0-3 with only `ntdll.so` replaced by one built on Anston's Mac from the same source with patch 0002 (same exports and linked libraries; scratch folders only, never released). `check-programs.sh` with D3DMetal passes untouched: silent install in 6 s, Social Club after 51 s. `lsof`: `Launcher.exe` loads `dxgi.dll`/`d3d11.dll` from `lib/schnitzel-wine-graphics`, the main `SocialClubHelper.exe` D3DMetal's `dxgi.dll` and `D3DMetal.framework`, the same split as CrossOver. Anston's test in the app (Pfanne `d3d`, same temporary engine as `schnitzel-engine-26.3.0-3-test`): the launcher installs, sets up Social Club and shows its window with D3DMetal. Its window first stayed invisible because CrossOver's launcher was running at the same time; both use `~/Documents/Rockstar Games` through Wine's Documents link, so the second launcher waited for its browser forever. Don't run the Rockstar Games Launcher in CrossOver and Schnitzel at once. - **CI engine with patch 0002 (run 45685952378, `26.3.0-dev.28`, all CI jobs green), November 25, 2026:** `check-programs.sh` passes untouched with D3DMetal (silent install 5 s, Social Club 51 s, launcher window shown at 71 s) and with WineD3D (Social Club 50 s, window 60 s; Steam connected after 125 s). The check now also requires the launcher's window to show (`WaitForWindow -> Active` in its log). Still to do: GTA V Legacy (cloned into Anston's `d3d` Pfanne from his CrossOver bottle with an APFS clone), then a 26.3.0-4 draft release.
- Checked, and the same as what CodeWeavers' Wine expects: `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` and `CX_APPLEGPTK_LIBD3DSHARED_PATH` pointing at `libd3dshared.dylib` (checked in `win32u/d3dkmt.c`, `win32u/vulkan.c`, `ntdll/unix/loader.c`).
- No longer needed after the cause was found: the one-at-a-time tests of D3DMetal's other DLLs, the variables and CrossOver's folder layout. (The first bisection round had been inconclusive because the launcher only writes its last log lines after its error dialog is closed.)
- Wine links the Windows user folders (Documents, Downloads, Music, Pictures, Videos) to the Mac user's own folders, in Schnitzel's Pfannen and in CrossOver's bottles alike; the launcher's logs and settings are shared between all of them. Checks now replace those links with empty folders.

### Toolchain

Every Windows-side (PE) file Schnitzel builds (Wine's DLLs for i386 and x86_64, the test programs, and later vkd3d and DXVK in M6) is built with **MinGW-w64 GCC 13.2.0, binutils 2.41 and MinGW-w64 v11.0.1**. These are the versions CrossOver 26.3.0's Wine records: "GCC: (GNU) 13.2.0" in each DLL, and GNU ld 2.41 in the PE headers. CodeWeavers' Wine is developed and tested with this compiler.
- **Why:** with llvm-mingw (Clang), CodeWeavers' `kernelbase.dll` keeps Steam from signing in and the Rockstar Games Launcher from installing Social Club; the same source built with GCC works (evidence above). The likely mechanism, not proven: GCC and Clang differ in how `DECLSPEC_HOTPATCH` prologues come out on x86_64, and Steam and Rockstar hook kernelbase functions.
- **Pinning:** all toolchain sources are in `inputs.json` with SHA-256 (two downloads from different servers matched). `build-toolchain.sh` builds one toolchain per architecture (win32 threads, DWARF-2 exceptions on i686, no ISL), checks the versions, and the workflow caches each by a key of only the toolchain pins and the script.
- **Check:** `check-pe-compiler.py` (run by `check-engine.sh`) fails a package if any PE file has another GCC version or a Clang marker, if a core DLL lacks the "GCC: (GNU) 13.2.0" marker, if an unmarked file isn't one of the 17 modules with no compiled code (the same ones CrossOver's Wine has), or if a file depends on GCC's or MinGW's runtime DLLs. It passes on CrossOver's Wine and fails on our Clang-built 26.3.0-1.
- Homebrew's `mingw-w64` (GCC 16), `bison` and `flex` are installed on Anston's Mac for local experiments only; builds always use the pinned toolchain.

### Tried and didn't work (don't repeat)

- **llvm-mingw (Clang) for Wine's Windows side:** breaks Steam sign-in and the Rockstar Games Launcher (kernelbase). Never switch back without rerunning the Steam check.
- **Plain install names** (`libgnutls.30.dylib`, no "/"): Wine's configure then records garbage SONAMEs; use `@rpath/<name>`.
- **llvm-mingw's unprefixed `clang` first in PATH:** it shadowed Apple's clang for Mac code.
- **Python's built-in HTTPS downloads:** fail on Anston's Mac (no certificate store); `fetch.py` uses curl.
- **DYLD_* through SIP-protected programs** (`perl`, inherited through `/usr/bin/env`): stripped. Pass them as arguments to `env`, then exec Wine.
- **`cmd | head -1` with pipefail:** can crash the command (xcodebuild did); use `awk 'NR==1'`.
- **Homebrew under Rosetta on Apple Silicon:** refuses to run; install bison and flex natively first.
- **Exporting `CC=clang` for the toolchain's Mac-side tools without naming the target compiler** for the MinGW runtime: its configure then compiles Windows code with the Mac's clang.
- **Pushing a tag to release:** a tag's run can't use the branch's caches; start releases with `gh workflow run engines.yml --ref <branch> -f release=<version>`.
- **DXMT as Auto's choice:** breaks the Rockstar Games Launcher (no `SwapDeviceContextState`); Auto picks D3DMetal or WineD3D.
- **CI checks that set up Wine by hand:** they missed that the app's Pfannen run from an engine assembly. Checks go through `schnitzel-cli`.
- **`ps -axo command | grep`** to find a Windows program: `ps` cuts long command lines short when it isn't writing to a terminal; use `pgrep -f`.
- **Steam's own launch options** (`-no-cef-sandbox`, `-cef-disable-gpu`): can't replace the per-program setting (no option for `--in-process-gpu`).
- **The loader memory reserve as the cause of Sikarugir 11.0_1's failure:** ruled out; the prefix check covers it.
- **Editing a bash script while it runs** breaks the run; **`timeout`** doesn't exist on macOS.

### ROSETTA_ADVERTISE_AVX

**ROSETTA_ADVERTISE_AVX=1** (done): measured on macOS 26.6.2, Rosetta hides AVX unless it's set; with it, Windows programs see AVX, AVX2, FMA, F16C and BMI2, and AVX2 code runs correctly. On by default in Pfannen (settings file version 2 migrates old files); a switch in the Pfanne settings comes with Phase 4.

### Program settings

Per-program settings live in SchnitzelKit's `ProgramSettings`, keyed by the program's file name (as Wine's `AppDefaults` are). Today they hold command line additions and `usesWineGraphics` (Wine's own d3d DLLs while the Pfanne uses D3DMetal or DXMT, Wine patch 0002, with an optional `pathEnding` for generic names; passed as environment variables, not the registry); recipes add more.
- `ProgramDefaults.builtIn` is what every Pfanne gets: only entries observed working in CrossOver (Steam's and Social Club's web helpers, and Wine's own graphics for the Rockstar Games Launcher).
- A Pfanne's own `programs` entries (from recipes or the user) are laid over them; an empty value turns a built-in one off.
- Pfanne setup writes them to `HKCU\Software\Wine\AppDefaults\<program>\CommandLineAppend` and counts them in the applied fingerprint, so existing Pfannen pick up new defaults on their next launch. The run log lists them.
- The engine side is Wine patch 0001. Sikarugir's engines read the same registry value, so the setting also works there.

## Later ideas (not now)

- Per-game launch shim for game-specific env vars.
- Compatibility reports: one click to export a recipe from a working Pfanne.
- Import existing Sikarugir wrappers and CrossOver bottles as Pfannen.

## Testing

Every step is compile-checked with `swift build` and unit-tested with `scripts/test.sh`. Before a branch is merged, it is tested in the app on an Apple Silicon Mac, following written steps that say what to build, click and check, and what output or screenshot to report if something fails.
