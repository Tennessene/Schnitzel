# Schnitzel — Project Plan

Schnitzel is a free, open-source Mac app for running Windows games, with an interface that is as easy to use as CrossOver's but has its own look. It is a **new SwiftUI app** that manages its own Pfannen and runs Wine directly. It builds on the work of Sikarugir, Kegworks and Wineskin, and reuses selected parts of **Whisky**'s WhiskyKit (GPL-3.0).

Schnitzel is a **standalone project**, not a GitHub fork: it lives at `github.com/Tennessene/schnitzel`. Early work began in a fork of Sikarugir's public landing repo (now `Tennessene/schnitzel-old`), which holds no app source code; its leftover files have been removed. Sikarugir's Creator.app and Launcher are closed source, so they couldn't be forked anyway (see Phase 0).

Tagline: *"Windows games, pounded flat for your Mac."*

Changes are made in small steps on feature branches, compile-checked and unit-tested, and tested on Apple Silicon before merging. There is no deadline: choose the approach that gives the best result, not the fastest one.

---

## Ground rules

- **Do not copy CrossOver.** No CrossOver code, logo, icons, colors, wording ("Runs Great", "Limited Functionality"), star graphics or pixel-exact layouts. Borrowing general UX patterns (sidebar, install catalog, per-container settings) is fine.
- **License: GPL-3.0.** Schnitzel as a whole is GPL-3.0 because it reuses Whisky code. Files copied from Whisky keep their original copyright headers plus a note describing Schnitzel's changes. Any code taken from Sikarugir's LGPL-2.1 Configure sources keeps its LGPL notices. Credit Sikarugir, Kegworks, Wineskin, Whisky, Wine and Gcenx in the README.
- **Never bundle D3DMetal.** Apple's license forbids redistributing it. Schnitzel detects a D3DMetal the user installed from Apple's Game Porting Toolkit and links to Apple's download page.
- **Native macOS look.** SwiftUI, system colors, SF Symbols, standard sidebar. Propose the approach before rewriting anything big.
- **Small steps.** One feature per branch, small commits, and each step must build and run before moving on. Ask before large refactors or deleting existing features.
- **Terminology:** a bottle/wrapper is a **Pfanne** (plural **Pfannen**) everywhere in the UI, e.g. "Neue Pfanne", "GTA V Pfanne". Internal code names can stay whatever is clearest.

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
- **Graphics layers:** designed so Phase 3 per-game choices work. Wine's `DllOverrides` can only choose between a DLL's *builtin* version (shipped inside the engine) and its *native* version (a file in the prefix's `system32`), never between two files of the same kind. So each Pfanne has two slots:
  - **Builtin slot, one provider per Pfanne.** D3DMetal and DXMT both work by replacing Wine's own builtin `d3d11`/`dxgi` (and for D3DMetal `d3d12`), so only one of them can be active in a Pfanne. Schnitzel builds an *engine assembly* for each combination it needs: an APFS clone (copy-on-write, so almost no extra disk space) of the pinned engine with the provider's files laid over it. Assemblies are cached under `Components/Assemblies/` and rebuilt if missing. Without an overlay, the builtin slot is whatever the engine ships (normally WineD3D).
  - **Native slot: DXVK.** DXVK's DLLs are copied into the Pfanne's `system32` and `syswow64`.
  - **Choosing per game** means choosing native or builtin per DLL, which `AppDefaults\<game>.exe\DllOverrides` can do. So per game, a Pfanne offers its builtin provider or DXVK. `d3d9` has no Metal provider, so builtin `d3d9` is always WineD3D.
  - Schnitzel writes explicit Pfanne-wide `DllOverrides` for `d3d9`, `d3d10core`, `d3d11`, `d3d12` and `dxgi`, so nothing depends on Wine's default load order. It never sets a global `WINEDLLOVERRIDES` for those DLLs, because the env var would override the per-game registry entries.
- **Env vars** (MSync, ESync, Metal HUD, D3DMetal options) are set per Pfanne when Schnitzel launches Wine.

---

## Order of work

1. **Phase 1:** skeleton and rebrand.
2. **Engine and Pfanne core.**
3. **Own engine builds.**
4. **Phase 2:** new main interface.
5. **Phase 4:** game presets (the Install screen needs the recipe format).
6. **Phase 3:** per-game graphics auto-detection.
7. **Phase 5:** the rest of the component updater.

Each phase is its own branch (`phase-1-rebrand`, and so on) with small commits.

---

## Phase 1: Skeleton and rebrand

- New Swift package with `SchnitzelKit` and the `Schnitzel` app, plus the `.app` build script.
- App name, bundle ID (`io.github.tennessene.Schnitzel`, based on the GitHub repo since no domain is owned), window titles and About window all say Schnitzel.
- **Pfanne/Pfannen** in all user-facing text from the start.
- New placeholder app icon (original design; schnitzel/pan themed is fine).
- `LICENSE` (GPL-3.0) and a README: what Schnitzel is, how to build it, credits to Sikarugir/Kegworks/Wineskin/Whisky/Wine/Gcenx, license.

## Engine and Pfanne core

- Copy the selected WhiskyKit files into `SchnitzelKit` with their headers and a change note.
- Download Wine engines into the versioned component store, checking each download against the SHA-256 digest GitHub publishes for it. Each Pfanne pins its engine. Switching keeps the previous version for one-click rollback.
  - **Engine sources.** Schnitzel's own engine, built from CodeWeavers' CrossOver source (see "Own engine builds"), becomes the default once a build passes testing. Until then, the **Sikarugir engines** built by Gcenx (`Sikarugir-App/Engines`, e.g. `WS12WineSikarugir11.0_1`) are used **only as a temporary testing and comparison reference**, not as Schnitzel's default. The official **WineHQ builds** by Gcenx (`Gcenx/macOS_Wine_builds`) can be installed for comparison but are **never the default**: upstream Wine lacks MSync and the Mac driver hooks D3DMetal needs.
  - If an engine archive contains Apple's D3DMetal, Schnitzel deletes it right after unpacking and uses only the user's own import, so Schnitzel never distributes D3DMetal.
- Import D3DMetal from the user's mounted Game Porting Toolkit disk image (its `redist/lib` folder) into `Components/D3DMetal/<version>/`. That copy stays on the user's Mac.
- Install DXVK (Gcenx's DXVK-macOS) and DXMT (`3Shain/dxmt`, builtin build) into the component store.
- Create a Pfanne (Wine prefix, default Windows 10 64-bit), run an `.exe` in it, open C: in Finder, write a log per run.
- Graphics layer setup per Pfanne as described under Architecture.
- A minimal working UI (list, create, run, open C:, engine and graphics choice) so each piece can be tested. Phase 2 replaces it with the real design.
- To verify on first real use, because they can only be checked with the actual downloads: the exact folder layout inside each archive, and whether Sikarugir engines already contain DXMT or MoltenVK. Schnitzel finds the Wine binary by searching the unpacked archive and shows what each component contains, so these show up in testing.

Status (November 2026): built on branch `engine-pfanne-core`, with unit tests for everything that doesn't need a real Wine run. Next: testing on Apple Silicon with real downloads, using the Sikarugir engine as the temporary reference.

## Own engine builds

Goal: Schnitzel's default engine is Wine compiled from CodeWeavers' CrossOver source drops (`codeweavers.com/crossover/source`), built in the open with GitHub Actions and published as Schnitzel engine releases.

What the source contains (checked with CrossOver 26.3.0, November 2026): `sources/wine` is Wine 11.0 plus CodeWeavers' changes (204 files changed and 17 added compared to WineHQ's Wine 11.0, 39 distinct `CW HACK` markers in 34 files). The main changes are MSync (`server/msync.c`, `ntdll/unix/msync.c`), the Mac driver hooks D3DMetal uses (`winemac.drv/d3dmetal*`), Mac driver and windowing fixes, wined3d using Vulkan for d3d10/11 on macOS, Rosetta and WoW64 fixes, and game-specific workarounds. The drop also contains CodeWeavers' MoltenVK, DXVK and vkd3d sources.

Plan:
- An `engines/` folder in this repository with the build script and the GitHub Actions workflow. Builds run on GitHub's macOS runners, which are free for public repositories.
- Steps: download a source drop and check its SHA-256 (CodeWeavers publishes no checksums, so the hash of the first download is recorded in the repository and later downloads must match it); install the toolchain (Xcode command line tools, `llvm-mingw` for the Windows-side DLLs, bison, flex and the libraries Wine links against); configure a WoW64 build (`--enable-archs=i386,x86_64`) for x86_64, since Wine on Apple Silicon runs under Rosetta; build; package `bin/`, `lib/` and `share/` into a `.tar.xz` laid out like the other engines; publish it as a GitHub release of this repository with its SHA-256 in the release and in a checksum file.
- Each release records exactly which source drop, toolchain versions and Schnitzel patches went into it, so any build can be reproduced.
- Gcenx's public build scripts (`Gcenx/macports-wine`, `Gcenx/macOS_Wine_builds`) are a reference for configure flags and dependencies. They have no license file, so Schnitzel learns from them and credits them but doesn't copy their files.
- **Never bundle Apple's D3DMetal.** The build includes only Wine's own side of the D3DMetal hooks. A CI check fails the build if `D3DMetal.framework` or `libd3dshared.dylib` appears in the package. CrossOver's `CX_APPLEGPTK_LIBD3DSHARED_PATH` variable may let Schnitzel point Wine at the user's imported D3DMetal instead of copying it into an engine assembly; check this during the phase.
- Schnitzel lists these releases as a third engine source (`ComponentSource`). When a build passes testing on Apple Silicon, it becomes the recommended engine and the Sikarugir engines are dropped from the default list.

What could go wrong:
- **Build environment.** CrossOver's own build setup isn't in the source drop, so dependency versions, configure flags and the mingw toolchain have to be worked out. GitHub's macOS runners change their Xcode and SDK versions over time and can break builds; pin versions and cache the toolchain.
- **Build time and limits.** A full Wine build takes well over an hour; caching helps. Jobs are limited to 6 hours.
- **Missing pieces.** Some CrossOver features may depend on parts not in the drop, or behave differently outside CrossOver (several hacks read `CX_*` variables). Each needs checking.
- **Dependencies.** FreeType, GnuTLS, SDL, MoltenVK and GStreamer have to be built or bundled, with their licenses included in the package.
- **Signing.** Without an Apple Developer ID, builds are ad-hoc signed and unnotarized. Schnitzel installs them itself, and Wine runs under Rosetta, so this is manageable, but it needs testing on a clean Mac.
- **Licensing.** Wine is LGPL-2.1, so every release must link to the exact source it was built from, including Schnitzel's patches. CodeWeavers' trademarks ("CrossOver") must not be used in Schnitzel's engine names; describe them as "built from CodeWeavers' Wine source".
- **Compatibility.** A first build may work worse than the Sikarugir engine. Compare the two with the same games before switching the default.

## Phase 2: New main interface

- **Sidebar:** list of Pfannen, plus "Install" at the bottom.
- **Pfanne detail view:** installed programs/games with launch buttons, and a settings section:
  - Windows version (default Windows 10 64-bit)
  - Graphics: Auto / D3DMetal / DXMT / DXVK / WineD3D
  - Sync: MSync / ESync / off
  - Toggles: DLSS, High Resolution Mode
  - Wine engine version (pinnable)
- **Install screen:** search box, a list of presets (Phase 4) with Schnitzel's own rating labels, and "Install something not listed" (pick an .exe or installer).
- "Run command / open .exe in this Pfanne", "Open C: drive in Finder", "Winetricks".

## Phase 3: Per-game graphics auto-detection

Goal: one Pfanne holds a whole Steam library, and each game automatically gets the right graphics layer.

1. Scan the Pfanne's drive (e.g. `Program Files (x86)/Steam/steamapps/common/*`) for game `.exe` files.
2. Parse each exe's PE import table and see which of these it loads: `d3d12.dll`, `d3d11.dll`, `d3d10*.dll`, `d3d9.dll`.
3. Choose (per game, between the Pfanne's builtin provider and DXVK; see Architecture):
   - d3d12 → builtin, which must be D3DMetal
   - d3d11 → builtin when the Pfanne's provider is D3DMetal or DXMT, otherwise DXVK
   - d3d9/d3d10 → DXVK
   - D3DMetal and DXMT can't be mixed per game inside one Pfanne. A Pfanne uses D3DMetal when it's imported, otherwise DXMT.
4. Write **per-app DLL overrides** into the Pfanne's registry under `HKCU\Software\Wine\AppDefaults\<game>.exe\DllOverrides`, so Wine loads the right DLLs when Steam launches that game.
5. Show the detected choice for each game in the UI, with a manual override and a "Reset to auto" button.
6. Settings that are env vars (some D3DMetal options, MSync, and similar) can't be set per game through the registry. Phase 3 applies them per Pfanne. Note any that need a per-game launch shim later.
7. Rescan when the Pfanne opens and on demand.

## Phase 4: Game presets (recipe files)

- A simple, documented recipe format (JSON or YAML), one file per game or launcher, in a `recipes/` folder so the community can add more by pull request.
- Each recipe has: name, rating, Windows version, graphics layer, sync, toggles, dependencies (Winetricks verbs), launcher(s) to install, notes shown to the user, and the date and component versions it was tested with.
- First recipes:
  - **GTA V Legacy (Steam):** Windows 10 64-bit; graphics D3DMetal; MSync on; DLSS off; High Resolution Mode off; install Rockstar Games Launcher **and** Steam in the **same Pfanne**; note: in the Rockstar Launcher go to Settings → GTA V and disable BattlEye (story mode only, GTA Online does not work); install "Grand Theft Auto V Legacy", not Enhanced (Enhanced currently needs a DirectX 12 feature D3DMetal lacks).
  - **Halo: The Master Chief Collection (Steam):** Windows 10 64-bit; graphics D3DMetal (fallback DXVK); choose "Play with anti-cheat disabled" at launch (campaign and offline only).
  - **Steam** and **Rockstar Games Launcher** as standalone launcher recipes.

## Phase 5: Component updater

Engine downloads, pinning and rollback come in the engine and Pfanne core phase. Phase 5 adds the updater UI for every component.

Show the installed version and the latest available version of each component, with update buttons:

| Component | Source | Auto-update? |
|---|---|---|
| Wine engine | Schnitzel's own builds from CodeWeavers' source (default once tested). Sikarugir engines as a temporary reference, WineHQ builds for comparison only (GitHub releases) | Yes |
| DXVK | Gcenx's DXVK-macOS (GitHub releases; last release 2023) | Yes |
| MoltenVK | KhronosGroup/MoltenVK (GitHub releases) | Yes |
| DXMT | `3Shain/dxmt` GitHub releases, builtin build (LGPL-2.1 from v0.81, MIT before) | Yes |
| D3DMetal | Apple Game Porting Toolkit | **No.** Detect the installed version and link to Apple's download page; requires the user's free Apple ID |

Rules:
- **Never auto-update a working Pfanne.** Each Pfanne can pin its component versions. Updates go to new or unpinned Pfannen, or happen when the user chooses.
- Keep the previous version on disk so the user can roll back with one click.

---

## Later ideas (not now)

- Per-game launch shim for game-specific env vars.
- Compatibility reports: one click to export a recipe from a working Pfanne.
- Import existing Sikarugir wrappers and CrossOver bottles as Pfannen.

## Testing

Every step is compile-checked with `swift build` and unit-tested with `scripts/test.sh`. Before a branch is merged, it is tested in the app on an Apple Silicon Mac, following written steps that say what to build, click and check, and what output or screenshot to report if something fails.
