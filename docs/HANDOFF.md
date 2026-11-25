# Handoff (November 25, 2026)

Temporary note for the next Claude Code session; Anston paused the work here. **SCHNITZEL_PLAN.md is the single source of truth**; if they disagree, the plan wins. Delete this file once the work below is done and the plan is up to date.

Branch: `own-engine-builds`, everything committed and pushed. **Don't merge it** (Anston: not until the D3DMetal problem is fixed and he has tested).

## Rules from Anston (also in Claude's memory)

- Ask before major changes to SCHNITZEL_PLAN.md (status and evidence are fine), before big refactors, removing features, or installing anything on his Mac outside the repo.
- Program tests (Rockstar Games Launcher, Steam) run **on his Mac, not in CI**, until he says otherwise. CI keeps builds, the package check and the prefix check. For check-only workflow changes use `[skip ci]` or `gh workflow run engines.yml --ref own-engine-builds -f engine-run=<run ID>`.
- Compare against CrossOver's own Wine (observe processes, environment, loaded files, his bottle read-only), never Sikarugir. Never open, copy or decompile CrossOver's closed files. Never bundle or copy D3DMetal into the repository or a release.
- Work on APFS clones of his Pfannen. Test Pfannen must not use the links to his real Documents/Downloads/… (check-programs.sh replaces them with empty folders). Test windows pop up on his screen; he doesn't need to click them.
- Small commits, compile-check every step, no deadline, most solid result. Report in plain terms first: what it means for him and what he needs to decide, then details, then exactly what to build, click and check.

## Where the work stopped

Anston's request (November 25), in order:
1. **In progress:** the Rockstar Games Launcher says "failed to initialize" in a Pfanne with D3DMetal 3.0 (Steam works there). Find the cause with evidence (same method as the DXMT one), fix it in Schnitzel (or the engine if the evidence says so), add a test, and make `check-programs.sh` pass with both WineD3D and D3DMetal. If the fix needs a big change (for example replacing engine assemblies with a CrossOver-style DLL path folder), **stop and explain the options first**.
2. Plan: fix the DXMT-fallback contradiction in the per-game graphics phase (step 3: "D3DMetal when imported, otherwise DXMT") to match Architecture's Auto rule; d3d11 → builtin when the provider is D3DMetal or a user-chosen DXMT, otherwise DXVK; recipes must never set DXMT for a Pfanne with the Rockstar Games Launcher (record DXMT v0.80 and the source checked: `3Shain/dxmt` main, `src/d3d11/d3d11_context_impl.cpp` line 1850, `UNIMPLEMENTED("SwapDeviceContextState")`, November 25, 2026); search plan and code comments for other DXMT-fallback assumptions; record the D3DMetal finding and fix.
3. Plan tidy-up, small edits only (see his message for the full list): renumber phases in order of work (1 skeleton and rebrand, 2 engine and Pfanne core, 3 own engine builds, 4 main interface, 5 recipes, 6 per-game graphics auto-detection, 7 component updater) with every cross-reference; move the CrossOver/Steam/Rockstar findings, Toolchain, Tried and didn't work, ROSETTA_ADVERTISE_AVX and Program settings out of the recipes phase (into own engine builds or a new "Findings and reference" section) with a pointer left behind; "Neue Pfanne" → "New Pfanne" and check UI strings for other German; status lines (phase 1 and engine/Pfanne core merged; M5 now: draft 26.3.0-3, GCC-built, passes CI, his test results with WineD3D and D3DMetal; Toolchain bullet: check-programs.sh replaced check-steam); runner names consistent with the workflow; DXMT license note (v0.80 MIT, v0.81+ LGPL-2.1 → link exact source and add the license to LICENSES/ when offered).
4. Run log size limit: per-log cap plus a limit on old logs per Pfanne, sensible defaults; a running program must keep running when its log hits the cap (cut or rotate, never block or kill); keep the newest output; tests; note in the plan. Don't delete his existing logs; tell him about big ones (his `Test` folder has a 16.9 GB `2026-11-24T030658 SteamSetup.log`).
5. Then M6 (vkd3d and DXVK). Engine releases stay drafts; Sikarugir 10.0_8 stays Recommended until M7 is done and he has tested.

## D3DMetal investigation: results so far

The evidence is also in the plan ("Rockstar Games Launcher with D3DMetal 3.0").
- Fails every time: his Pfannen `test4` and `test-d3d`, and 2 of 2 fresh Pfannen via `D3DMETAL="$HOME/Downloads/D3DMetal/GPTK 3.0/redist" engines/scripts/check-programs.sh .build/debug/schnitzel-cli ~/Downloads/schnitzel-engine-26.3.0-3.tar.xz /private/tmp/claude-501/r-<tag> rockstar`. WineD3D control: passes (Social Club after 60 s).
- In `launcher.log`, the launcher reaches "Initializing group 1" and connects to its service, but its worker thread never starts; it stops after about 9 s and exits with code 1.
- **Lead:** started directly with `schnitzel-cli run Check ".../Launcher/Launcher.exe"`, its output shows `HRESULT DXGID3D10CreateDevice(HMODULE, void *, void *, unsigned int, const D3D_FEATURE_LEVEL *, unsigned int, void **)`, then `Exited with status 1`. Probably D3DMetal's `dxgi` reporting an unimplemented function. Check where it comes from (which DLL prints it) and whether CrossOver avoids the call, for example by Wine's own `d3d10*`/`dxgi` handling, a different file set, or `d3d10core` coming from Wine.
- The environment variables match what CodeWeavers' Wine expects (`CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal`, `CX_APPLEGPTK_LIBD3DSHARED_PATH`).
- The first bisection round was **inconclusive**: the launcher writes its final log lines only after its error dialog is closed, so the harness (`launch.sh`, 60 s, waiting for "Stopping the background service") timed out on every variant, baseline included. A better verdict: the launcher process exits with status 1 or its dialog window appears, or the `DXGID3D10CreateDevice` line shows up in Schnitzel's run log.
- Still to test, one at a time, on the plain D3DMetal assembly: without `nvapi64`/`nvngx-on-metalfx`/`atidxx64`; Wine's `d3d10` instead of D3DMetal's; Wine's `d3d10core` (CrossOver's apple_gptk folder has d3d11, d3d12, dxgi, nvapi64; check whether d3d10 is in it); each environment variable empty; CrossOver's layout (Pfanne on WineD3D with `--env WINEDLLPATH=<gptk>/lib/wine` in front); which MoltenVK is loaded. Then compare with CrossOver: start his bottle's launcher only if he agrees, and observe its loaded files with `lsof`.
- Scratch test data (may be cleared by a reboot): `/private/tmp/claude-501/r-d3d-1`, `r-d3d-2` (D3DMetal Pfannen named `Check`, data folder `.../d`; use `SCHNITZEL_DATA_DIR=<that>/d`), `r-wined3d-1`. Wine fails on DLL paths over 260 characters, so keep test folders short.

## Done this session (all pushed)

- Auto graphics: D3DMetal if imported, otherwise WineD3D, never DXMT (Anston's choice); Pfanne view note; test.
- `schnitzel-cli` (Sources/SchnitzelCLI): install, download, import-d3dmetal, create, set graphics, run (`--winedebug`, `--env`), env, stop, wait. `SCHNITZEL_DATA_DIR` moves all data. `PfanneDefaults` shares the new-Pfanne component picks with the app.
- `engines/scripts/check-programs.sh` replaces check-steam.sh (local only now).
- Intel Macs no longer need Rosetta to create Pfannen (`Rosetta.canRunWine`).
- Workflow: a damaged cache download is retried once; `engine-run` checks-only mode; the program check job was removed (local only).
- Plan: GCC toolchain done, Rosetta/ARM64 note, DXMT evidence, program check. Draft 26.3.0-2 deleted; draft 26.3.0-3 is the current one.
