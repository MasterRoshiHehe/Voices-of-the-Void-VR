# Voices of the Void VR mod

Adds VR to Voices of the Void (Unreal Engine 4.27.2, CL-18319896; D3D11 and D3D12 both compiled in, default RHI unconfirmed) for Quest 3 via Virtual Desktop (assumed; see STATUS.md).
Built on UEVR (praydog) as the VR core: this repo holds the UEVR profile, Lua scripts and any UE4SS-side helpers, not a hand-rolled renderer. See RESEARCH.md.
Game install: F:\Games\Voices of the Void. Dev folder: F:\Moddings\VOTV\Claude.
Project scope: single-player first (co-op via Multivoid untested); [user's decision on publisher guidance; see RESEARCH.md].

## Before you change anything

- Read `STATUS.md` (the shared scratch pad; add a dated entry before you stop), `RESEARCH.md` and
  `CONTROLS.md` if they exist. Build on what's there; don't redo or undo another agent's work.
  Old handoff notes are historical: check the latest status before acting on them.
- Decisions, measurements and open issues go in versioned files with dates and run or commit IDs.
  Nothing should depend on chat history or private memory.

## Rules

- **Don't ask the human to check what you can check.** You can see the headset through SteamVR's
  VR View (or the mod's own eye snapshots), drive the controllers with the test driver, and read
  the trace and logs. Ask for the headset only for feel and comfort.
- **But get a first headset look early.** Once stereo and the camera pass their checks, ask for
  five minutes in the headset before performance work, soak runs or new features. Scale, held
  objects and the HUD are seen at once by a person and missed by automated checks.
- **Never wave off a failing check.** Fix the check with a test, or write why the FAIL doesn't
  apply in the run log, before building on the result.
- **Soak before "ready", and log every crash.** Several minutes of the heaviest gameplay over
  several fresh launches before calling a build playtest-ready; every crash goes in the crash
  ledger in `STATUS.md` with its signature and run.
- **Look, don't count.** A submission counter going up isn't proof an image reached the headset.
  Check both eyes with `frame_check.py` (test-harness skill) and a known-bad `--reject` or golden
  `--ref`; only VERDICT PASS confirms. INCONCLUSIVE means it couldn't tell, not that it worked.
- **Verdicts before evidence.** Every image and log you read is re-sent with every later request.
  Read check verdicts and summaries first; open an image (the failure preview) or query the
  trace only when a check fails. Hand checks and per-issue work to fresh sub-agents or worktree
  sessions that report back verdicts and file paths.
- **Reproduce before you fix.** Every reported issue gets a failing reproduction (test driver
  script, eye snapshot comparison, trace check or unit test) before the fix, and the same check
  passing after. If you can't reproduce it, say what you'd need.
- **One run owns the game install.** Whoever has the game running owns its files and the headset;
  other sessions don't launch the game or install or replace the mod's files until that run ends.
- **Always clean up.** The launcher removes the mod after every run, even on failure.
- **Publisher guidance and user responsibility.** The user is responsible for checking what the
  game's publisher supports and permits for mods, anti-cheat and online play, and deciding the
  project's scope. Help by finding dated official sources, describing relevant requirements
  and flagging uncertainty. Record their decision in `RESEARCH.md` and `STATUS.md`; don't impose
  a blanket offline-only rule or treat technical feasibility as publisher approval.
- Every tunable value (thresholds, offsets, angles) is a live setting, not a constant.
- **Pin the game build and fail closed.** Every hard-coded address goes through the per-build
  lookup table; an unknown build or mismatched bytes means no hook. If the headset suddenly shows
  nothing, check the exe's build first. Porting to a new build: the `vr-mod-game-patches` skill.
- **Nothing of the game's in the repo.** No decompiler output, disassembly, crash dumps or game
  data fixtures; byte patterns from game code are digests, never literals. Shipping to players:
  the `vr-mod-release` skill.
- **Discover capabilities before choosing interactions.** Camera mode and input mode are separate
  decisions. Use only the game's actual actions and available hooks; combat, physical grabbing,
  skeletal IK and virtual gamepad output are optional. Record action semantics, contexts,
  integration routes and observable success conditions in `CONTROLS.md`.
- **Requested input isn't a game outcome.** Verify the game accepted/performed the action.
  Release/neutralise outgoing controls on context changes and focus/tracking loss, and prevent
  held inputs from becoming unrelated actions on return.
- **Keep a vendor-neutral rendering baseline.** Frame tracking, stereo delivery and essential
  diagnostics must work without an optional vendor SDK or upscaler. Separate required graphics
  capabilities from tested GPU/driver/runtime combinations; missing hardware stays untested.
  A flat fallback or a submission counter is not proof of stereo.
- **Record broad workarounds when adding them.** In `STATUS.md`, register disabled optimisations,
  forced refreshes, duplicated work, extra waits and widened bounds with their reason, scope,
  A/B switch, scene costs and revisit criterion. Revisit them on new scene types and before release.
- **Measure beyond the test room.** Rendering changes need both-eye correctness checks and
  repeated, matched performance comparisons in representative real gameplay. Keep temporal
  histories per eye and preserve visibility needed by either eye. Use the test-harness skill's
  compatibility and performance references; unresolved measurements remain explicit release gaps.

## Rules carried over from the Sims 4 VR project (VR-MOD-HANDOFF.md)

- One change per build, one build per test. Builds start directly in the mode under test.
- Prove the cause from data (logs, dumps, marks) before coding a fix. The headset result outranks logs.
- Before hooking or changing game behaviour, read the relevant dumped classes/Blueprints (UE4SS dumps, FModel) and say which were checked.
- Never crop the game's rendered UI onto VR elements; use a separate widget layer or redraw from game data.
- Comfort defaults: haptics off, UI never re-follows the player, sound stays 3D, never change the game's clock.
- Settings autosave on change. Bound every wait; never hang on the runtime (Virtual Desktop can stall `xrEndFrame`).
- UEVR source is all-rights-reserved: use it as a tool and through its plugin/Lua API, never copy its code.
- **Both runtimes, every feature** (user requirement 2026-11-26 23:42): the game must stay playable on OpenXR and on SteamVR. OpenXR through Virtual Desktop is the primary test and the default; SteamVR (`Play-VOTV-VR-SteamVR.bat`, `run-vr.ps1 -Runtime OpenVR`) is the parallel test, one run at a time, and the script restores the OpenXR default afterwards. Verify each feature on both. The SteamVR path also allows the kit's mirror capture (`tools\mirror_capture_build\openvr_mirror_capture.exe`) for automated both-eye checks.
- **Default runtime is not SteamVR** (user preference 2026-11-26, refined by the line above): run UEVR on OpenXR through the active runtime (Virtual Desktop's VDXR, checked in HKLM\SOFTWARE\Khronos\OpenXR on 2026-11-27). Normal launches never start SteamVR (only the SteamVR test launcher does); if the active runtime is SteamVR, tell the user (system setting) rather than changing it. On OpenXR runs rely on UEVR logs, the user's description, or a VD-side capture.
- Hardware under test (assumed): Quest 3 via Virtual Desktop, RTX 4080 Super, i7-13700K, Windows 11.

## Commands

Fill these in as the tooling gets built.

- Build: none yet (stage A is UEVR + profile only; baseline profile in `profile\VotV-Win64-Shipping\config.txt`)
- Tests: harness scripts with `.venv\Scripts\python -I .agents\skills\vr-mod-test-harness\scripts\frame_check.py ...`
- Launch a test run: double-click `Play-VOTV-VR.bat` (repo root, or the copy in the game folder) = `powershell -ExecutionPolicy Bypass -File scripts\run-vr.ps1` (options: `-InjectDelaySeconds N`, `-MaxRunMinutes N`, `-ResetProfile`, `-Runtime OpenXR|OpenVR`, `-NoInject`, `-DryRun`, `-LaunchExe Shipping`); logs in `logs\<timestamp>\`
- Run verdict: `scripts\check-run.ps1 logs\<run>` (run-vr.ps1 calls it at the end; writes `verdict.txt`); feature x runtime table: `scripts\runtime-matrix.ps1` -> `checklists\runtime-matrix.md`. Pass `-Feature <name>` to run-vr.ps1 so runs are tracked per feature.
- Test driver: [command]
- Voice playtest: see the vr-playtest-loop skill
- Git: `scripts\git-feature.ps1 commit|merge|status` (see Git workflow)

## Git workflow

Repo: https://github.com/MasterRoshiHehe/Voices-of-the-Void-VR (**public**: everything pushed is
visible to anyone, so no game files, dumps, logs, local paths with usernames or secrets).

- **Branches.** `main` = released builds only; it moves only when the user says a release is
  ready (then `dev` is merged into `main` and tagged). `dev` = integration. All work goes on
  `feature/<topic>` branches (lowercase, e.g. `feature/vr-menu`, `feature/motion-controllers`),
  one per thread or issue, merged into `dev` when that piece works (its check passes).
- **The shared folder stays on `dev`. Never `git switch`/`checkout`/`stash`/`reset --hard`/
  `clean` here,** and don't stage with plain `git add`: several threads edit this folder at once,
  and those commands rewrite or drop other threads' files. Use the script, which commits from a
  private index and never touches files on disk:
  - `powershell -ExecutionPolicy Bypass -File scripts\git-feature.ps1 commit -Branch feature/<topic> -Message "<what and why>" -Paths <file1>,<file2> -Push`
    commits **only the files your thread changed** (as they are on disk) to your branch,
    creating it from `dev` if needed. Shared files (`STATUS.md`, `AGENTS.md`, `CONTROLS.md`)
    hold other threads' edits too; commit them anyway, since the merge combines lines.
  - `... git-feature.ps1 merge -Branch feature/<topic> -Push` merges your branch into `dev`
    (merge commit) and pushes both. It stops on a conflict instead of guessing; resolve it on
    your branch and merge again.
  - `... git-feature.ps1 status` lists unmerged feature branches and uncommitted files.
  - **Push rejected (non-fast-forward, origin/dev moved ahead):** run
    `... git-feature.ps1 sync -Push`. It fetches origin/dev, fast-forwards or makes a merge
    commit (`STATUS.md` merges by union, so two new log entries both survive), updates only the
    on-disk files nobody here edited, three-way merges incoming changes into files a thread has
    edited, and pushes dev. `merge -Push` does this sync first automatically. If it reports
    CONFLICT, LEFT AS IS or UNION MERGE ... WOULD DUPLICATE, it has changed nothing for those
    files: stop and tell the repo thread or the user. Union merges suit only adding new log
    entries; when you change an existing STATUS.md line (the install lock above all), commit and
    merge it promptly so two threads don't edit the same line on different branches. Never `git pull`, `git rebase`, `git merge origin/dev` or force-push here.
  - Merge into `dev` only in this folder (with the script), not on GitHub and not from another
    clone or cloud session; if you work elsewhere, push your feature branch and ask for the merge.
  - Pushing: `-Push`, or `git push -u origin feature/<topic> dev` from either tool. The repo
    pins the GitHub account (`credential.https://github.com.username MasterRoshiHehe`, remote URL
    `https://MasterRoshiHehe@github.com/...`), so no account picker should pop up. Set
    `GCM_INTERACTIVE=never` for agent pushes (the script does) so a missing credential fails
    instead of putting a dialog in front of the user; if it fails, tell the user, don't retry in a loop.
    Don't change those two settings. Retry network errors up to 4 times.
- **Commit often, small.** One change per commit, message says what and why, plus the run ID or
  check verdict when there is one. End messages with the `Co-Authored-By` line you're given.
- **Never commit** anything `.gitignore` excludes: `tools\` (UEVR, OpenVR SDK, mirror-capture
  build), `.venv\`, `logs\`, `runs\`, captures, dumps (UE4SS/FModel output), archives such as
  `kit-setup.tgz`, game files. Fetch steps for the tools are in `README.md`. Never force-push
  `dev` or `main`; never `--no-verify`.
- A separate git worktree (`git worktree add ..\VOTV-<topic> feature/<topic>`) is fine for
  bigger refactors, but it has no `tools\` folder, so runs still launch from this folder.

## Skills

- `vr-mod-research`: the research pass. Run it before writing mod code.
- `vr-mod-test-harness`: see, play and measure without the human.
- `vr-playtest-loop`: voice-recorded playtests and the reproduce-before-fix loop.
- `vr-mod-game-patches`: build pinning, the address table, and porting the mod after a game update.
- `vr-mod-release`: the player package and the public-repo cleanup, once the human decides to share.
- `vr-controls-design`: capability discovery, camera/input choices, context-specific actions,
  optional combat/body interactions and applicable defaults.
