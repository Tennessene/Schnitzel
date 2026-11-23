# Schnitzel — Project Plan

Schnitzel is a free, open-source Mac app for running Windows games, with an interface that is as easy to use as CrossOver's but has its own look. It is a **new SwiftUI app** that manages its own Pfannen and runs Wine directly. It builds on the work of Sikarugir, Kegworks and Wineskin, and reuses selected parts of **Whisky**'s WhiskyKit (GPL-3.0).

Schnitzel is a **standalone project**, not a GitHub fork: it lives at `github.com/Tennessene/schnitzel`. Early work began in a fork of Sikarugir's public landing repo (now `Tennessene/schnitzel-old`), which holds no app source code; its leftover files have been removed. Sikarugir's Creator.app and Launcher are closed source, so they couldn't be forked anyway (see Phase 0).

Tagline: *"Windows games, pounded flat for your Mac."*

Claude Code writes the code; Anston doesn't want to dig through or hand-write it himself. He reviews and tests on his Apple Silicon Mac. There is no deadline: choose the approach that gives the best result, not the fastest one.

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
- **Graphics layers:** designed so Phase 3 per-game choices work. Schnitzel never sets a global `WINEDLLOVERRIDES` for the d3d DLLs (`d3d9`, `d3d10core`, `d3d11`, `d3d12`, `dxgi`), because it would override per-game registry entries. Layer selection goes through the Pfanne's registry (`DllOverrides`, and per game `AppDefaults\<game>.exe\DllOverrides`). The engine and Pfanne core phase verifies which layers can coexist in one Pfanne, since `DllOverrides` only chooses between native and builtin DLLs.

---

## Order of work

1. **Phase 1:** skeleton and rebrand.
2. **Engine and Pfanne core.**
3. **Phase 2:** new main interface.
4. **Phase 4:** game presets (the Install screen needs the recipe format).
5. **Phase 3:** per-game graphics auto-detection.
6. **Phase 5:** the rest of the component updater.

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
- Download Wine engines from Gcenx's wine-crossover releases into the versioned component store. Each Pfanne pins its engine. Switching keeps the previous version for one-click rollback.
- Create a Pfanne (Wine prefix, default Windows 10 64-bit), run an `.exe` in it, open C: in Finder, write a log per run.
- Graphics layer setup per Pfanne as described under Architecture, including detecting the user's D3DMetal.

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
3. Choose:
   - d3d12 → D3DMetal
   - d3d11 → D3DMetal (fallback DXMT, then DXVK)
   - d3d9/d3d10 → DXVK
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
| Wine engine | Gcenx's wine-crossover builds (GitHub releases) | Yes |
| DXVK | Gcenx's DXVK-macOS (GitHub releases) | Yes |
| MoltenVK | KhronosGroup/MoltenVK (GitHub releases) | Yes |
| DXMT | upstream GitHub releases | Yes |
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

Claude Code compile-checks every step with `swift build` but can't click through the app. After each step, tell Anston exactly what to build, click and check, and what output or screenshot to send back if something fails.
