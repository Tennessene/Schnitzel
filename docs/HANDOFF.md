# Handoff: own engine builds (November 24, 2026)

Temporary note for the next Claude Code session. **SCHNITZEL_PLAN.md is the single source of truth**; if this note disagrees with it, the plan wins. Read this, check the plan is up to date, then delete this file.

Branch: `own-engine-builds`. Commits are SSH-signed under Anston's GitHub noreply address (global git config).

## Where things stand

- **M1, M2, M3: done, passing on GitHub Actions.**
- **M4 (Wine, package, checks): in progress.** Wine's configure passes. Run **45349504731** is building Wine with the latest fix (build-time rpaths so `sfnt2fon` finds FreeType). It may have finished by the time you read this: check it with `gh run view 45349504731`.
- **M5:** the release job, the `schnitzel-engines` source, own-libraries detection and **Install from file…** (with SHA256SUMS checks and duplicate matching by SHA-256) are all written and committed. The app tests pass (75, via `scripts/test.sh`). Not yet done: a tagged build and the draft release.

## Exact next steps

1. Look at run 45349504731. If `Wine (M4)` failed, read `gh run view <id> --log-failed` and the `wine-logs` artifact, fix the problem, and push. Watch for configure finding macOS functions newer than 14.0; the fix is `ac_cv_func_<name>=no`, as for libinotify. Pushing changes under `engines/` cancels a running build, so wait for jobs whose cache you want to keep.
2. Get `package` (package-engine.sh, macho.py fix, check-engine.sh) and both `check-prefix` jobs (Intel, and Apple Silicon with Rosetta) green. The prefix check expects "msync: up and running" in wineboot's output. If that line doesn't reach the log, check where wineserver's stderr goes before loosening the check.
3. Run the Rosetta fallback trial once: `gh workflow run engines.yml --ref own-engine-builds -f rosetta=true`. Record the result in the plan.
4. Tag `engine-26.3.0-1` and push the tag. Tag runs can't use the branch's caches, so this is a full build of about 3 hours. Check that a **plain draft** (not a pre-release) appears with the engine, `SHA256SUMS` and the source files.
5. Update SCHNITZEL_PLAN.md (M4 and M5 done, timings, lessons). Then report to Anston in plain terms. Test steps: download the draft's engine archive and SHA256SUMS from GitHub (signed in), use Components → Wine Engines → Install from File…, create a Pfanne with `schnitzel-engine-26.3.0-1`, install and run Steam, and say what to send back if something breaks (the Pfanne's log from Show Log, a screenshot, the Components notes).

## Lessons from this session (also in the plan where lasting)

- Libraries need `@rpath/<name>` install names: Wine's configure keeps only what follows the last "/". Plain names produce garbage SONAMEs.
- llvm-mingw's unprefixed `clang` shadows Apple's, so it goes last in PATH, with `CC=/usr/bin/clang`.
- `cmd | head -1` with pipefail can crash the command (xcodebuild did); use `awk 'NR==1'`.
- Homebrew doesn't run under Rosetta: install bison and flex natively first.
- The runner reported about 136 GB free disk, far more than the documented 14 GB.
