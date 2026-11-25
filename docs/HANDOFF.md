# Handoff (November 24, 2026)

Temporary note for the next Claude Code session. **SCHNITZEL_PLAN.md is the single source of truth**; this note only says where the work stopped. If they disagree, the plan wins. Read this and the plan's "Own engine builds" section (especially "Toolchain" and "Tried and didn't work" under Phase 4's CrossOver notes, and the M1–M5 milestones), confirm the plan is up to date, then delete this file.

Branch: `own-engine-builds` (everything is committed and pushed). Commits are SSH-signed under Anston's GitHub noreply address (global git config).

## Rules from Anston (also in Claude's memory)

- Ask before major changes to SCHNITZEL_PLAN.md; recording progress and evidence is fine.
- Update this handoff only when Anston asks.
- Ask before installing anything on Anston's Mac outside the repo. Already installed and kept: Homebrew `mingw-w64` (GCC 16, local experiments only), `bison`, `flex`.
- CrossOver: run and observe only (process arguments, environment, loaded files, the user's own bottle files under `~/Library/Application Support/CrossOver/Bottles/GTA V`, read-only). Reimplementing its closed parts is allowed; never open, decompile, copy or redistribute its closed files (the `wine` launcher script, `cxcompatdb.so`, `cxfixes.xml`). Never write Anston's Steam ID or login tokens into the repo or plan.
- No deadline: most solid result, small commits, compile-check every step, ask before big refactors. Plain, simple explanations first, then technical details.

## Where the work stopped

Anston's current request (in progress): **switch the whole Windows side of the engine to MinGW-w64 GCC like CrossOver, and ship draft release 26.3.0-3.** His points, with status:

1. Build every PE file with MinGW GCC instead of llvm-mingw. **Done in the scripts:** `build-toolchain.sh`, `build-wine.sh` (passes `i386_CC`/`x86_64_CC`, fails if configure didn't take them), `check-toolchain.sh` (test programs, `-static`), `package-engine.sh` (licenses from the toolchain), release notes. llvm-mingw is gone from `inputs.json` and the build. vkd3d and DXVK aren't built yet (M6); tell Anston they'll use the same toolchain when M6 builds them.
2. GCC 13.2.0, matching CrossOver. **Pinned:** binutils 2.41 (CrossOver's PE headers say linker 2.41), GCC 13.2.0, MinGW-w64 v11.0.1, MPFR 4.2.1, MPC 1.3.1 (+ GMP 6.3.0), each downloaded from two servers with matching SHA-256.
3. Reproducible pinning and caching. **Done:** a `mingw-gcc` matrix job per architecture, cached by a key of only the toolchain pins + `build-toolchain.sh` + `common.sh` (computed in the `config` job). The Wine key includes the toolchain key.
4. Engine check for the compiler. **Done:** `check-pe-compiler.py`, run by `check-engine.sh`. It passes on CrossOver's Wine and fails on our Clang 26.3.0-1.
5. Nothing from CrossOver.app in the repo, a build or a release: **confirmed** (no binaries in git history, no CrossOver.app paths in tracked files, CI never has CrossOver). Scratch prefixes and copies: **deleted**.
6. Plan updated: **done** ("Toolchain", the evidence, the check, "Tried and didn't work").
7. Draft 26.3.0-3 passing on both runners, plus a Steam network test: **not done yet.**
   - `check-steam.sh` is written and committed. Locally it fails on the Clang 26.3.0-2 as it should (4339 rescheduled connection attempts in 420 s). It still needs a positive run on a GCC engine and adding to the workflow. Plan: a job like `check-prefix` on both runners, `needs: [config, package]`, and add it to the release job's `needs` if it's reliable.
   - Steam's installer comes from Valve's CDN and isn't pinned; that's fine for a test, but say so to Anston and judge reliability over a couple of runs before making it required.
   - A Rockstar Games Launcher test isn't planned (it needs its installer flow); say why if asked.

## Exact next steps

1. Watch CI run **#17** (`gh run view 45522087113`). Its first attempt (#16) failed building binutils for i686: the bundled zlib's `fdopen` macro clashes with the macOS 26 SDK. #17 builds binutils and GCC `--with-system-zlib` and has `fail-fast: false`. Expect a few more toolchain fixes; read the job log (`gh api repos/Tennessene/Schnitzel/actions/jobs/<id>/logs`) and the `mingw-gcc-<arch>-logs` artifact. The toolchain build takes roughly an hour per architecture, and the jobs run in parallel.
2. Then Wine builds with GCC. Watch `check-engine.sh`'s new compiler check. If an unmarked file that isn't in `NO_CODE` turns up, check whether it really has no compiled code before adding it, and say so in the commit. Also check that no PE file imports `libgcc_s_*`/`libstdc++-6.dll`/`libwinpthread-1.dll`.
3. Run `check-steam.sh` on the GCC dev build's artifact (locally first, then add the CI job).
4. Release: `gh workflow run engines.yml --ref own-engine-builds -f release=26.3.0-3`. If a queued check gets cancelled, use `gh run rerun <id> --failed`. Then delete the old 26.3.0-2 draft only if Anston agrees.
5. Report to Anston, then give him the test steps:
   - download `schnitzel-engine-26.3.0-3.tar.xz` and `SHA256SUMS` from the draft (signed in), and install with Components → Wine Engines → Install from File…;
   - create a brand-new Pfanne with 26.3.0-3;
   - install the **Rockstar Games Launcher first**, then **Steam**, and sign in to both;
   - if something breaks, send the Pfanne's latest log (Show Log), a screenshot, and the step.

## Facts worth knowing

- Draft releases: only **26.3.0-2** exists (Clang build: Steam's window shows, but sign-in and Rockstar fail). Releases are started with `workflow_dispatch` `release=<version>`; the tag is created on publish.
- The app side for these tests is done: per-program settings (Steam's and Social Club's helpers, Wine patch 0001), Install from File, AVX on by default (settings file version 2). 80 tests pass with `scripts/test.sh`.
- Anston's Pfannen: "poopy" (26.3.0-1) and "kaka" (26.3.0-2). His CrossOver bottle "GTA V" is the working reference (Steam signs in, GTA V Legacy runs).
- The Rosetta fallback build trial (`-f rosetta=true`) is still to do, now with the GCC toolchain.
