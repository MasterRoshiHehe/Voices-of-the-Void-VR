# Status

The agents' scratch pad for this mod. Every session reads this first and adds a dated entry to the
Log (newest first) before it stops: what changed, the evidence (commit, run folder, test result),
and what's next. Keep the sections above the Log current. Keep it factual; it's how the next
session (or the other agent) picks up the work.

## Current state

- Runtime: OpenXR via UEVR (proposed, RESEARCH.md §4)
- Stereo: same-frame (UEVR Native Stereo), fallback Synchronized Sequential (proposed)
- Camera mode(s): first-person embodied (HMD drives view)
- Input mode(s): stage A = existing controls (gamepad/keyboard); stage B = tracked pointing from the hand; stage C optional (user plan 2026-11-26)
- Capabilities and action mappings: [RESEARCH.md / CONTROLS.md; confirmed hooks and unknowns]
- Publisher guidance and chosen scope: [dated sources in RESEARCH.md; user decision and unknowns]
- Launch for testing: `Play-VOTV-VR.bat` (repo root; copy in `F:/Games/Voices of the Void/`) = `powershell -ExecutionPolicy Bypass -File scripts\run-vr.ps1` (stage A; logs to `logs\<timestamp>\`)
- UEVR: 1.05 stable, `tools\UEVR\1.05\UEVR\` (not in git); profile baseline `profile\VotV-Win64-Shipping\config.txt`, seeded to `%APPDATA%\UnrealVRMod\VotV-Win64-Shipping\config.txt`
- Who owns the game install right now: menu session (this thread), for the menu-camera test run; claimed 2026-11-27 00:54, deadline 01:30. Clear when the run ends.

## Rendering compatibility

- Minimum capabilities: [graphics API/features, formats/resource operations, runtime and memory
  requirements; confirmed versus unknown; vendor-neutral AA/stereo baseline]
- Evidence matrix: [GPU model/driver, OS/runtime/headset, game/mod build, AA, actual input/output
  size, scenes, run IDs, image checks, recovery, performance and human comfort verdict]
- Claims: [tested / experimental / untested / unsupported per combination; missing vendor
  middleware test is separate from real hardware validation]
- Unsupported settings: [visible fallback/reason and how supported stereo resumes]

## Rendering workarounds

One entry per broad workaround; link longer evidence rather than copying logs here.

- [ ] [ID / introduced commit: optimisation disabled or work forced; correctness reproduction;
  exact scope and activation log; A/B switch; costs by representative scene (unknown stays
  unknown); narrower replacement or removal criterion; revisit on new scene types and release]

## Performance and release evidence

- Baselines and budgets: [fixed checkpoints/routes, matched settings and builds, repeated A/B
  runs, timing/throughput/tail/pose-age budgets and configurable regression review triggers]
- Results: [small scene plus applicable dense interior, terrain and busiest gameplay; CPU/GPU
  times, fresh delivered stereo, gaps/drops and pose age; missing metrics and profiler overhead]
- Package audit: [package hash, effective defaults/settings, active workaround IDs, diagnostics
  off, normal-launch and settings/load recovery checks; evidence and untested gaps]

## Waiting on the human

- [ ] Agree the plan in RESEARCH.md (UEVR + profile/Lua, UE4SS helpers)
- [ ] Confirm hardware is the Sims rig: Quest 3 via Virtual Desktop, RTX 4080 Super
- [x] Intended experience (2026-11-26), staged one step at a time: A) head tracking + gamepad, HUD on a floating panel (FIRST); then B) motion controllers with hand aiming; then maybe C) full hands-on interaction. HUD/menu placement details still open.
- [ ] Paste the old Reddit guide text (blocked to automated fetch)
- [x] Python venv: done 2026-11-27 (Python 3.14.5 at C:\Python314; numpy 2.5.5, Pillow 13.0.0)
- [ ] First stage A run: start Virtual Desktop, connect the Quest 3 (VDXR as OpenXR runtime), then run `scripts\run-vr.ps1`. If the injector window shows, check OpenXR is ticked.
- [ ] Approve or change the controller layout in `CONTROLS.md` §2 (proposed 2026-11-27)
- [ ] Voice-recorded playtests: yes/no
- [ ] Scope decision on publisher guidance (no official policy found)

- [x] First headset look: done 2026-11-26 23:41 (OpenXR run 00:28): playable, looks and runs great; HUD followed mouse pitch (fix under test)
- [ ] [Headset checks that need a person: what to launch, what to do, what to look for]

## Open issues

- [ ] **Main menu cross-eyed** (user 2026-11-26 23:24: "vr looked fine in game, the cross eyedness was only for the main menu"; user 2026-11-26 23:24 confirmed the mirrored left/right turning was also menu-only; gameplay stereo looked fine). Also on OpenXR via VD (user 23:43 on the HUD-fix run: "the main menu is still super crosseyed"), so it is not runtime-specific. In-game stereo checked OK on captures (see log). Not reproduced on a capture yet (all 15 snaps were in-game). Candidate direction, not yet evaluated: show the menu level as a flat 2D panel (UEVR 2D screen mode toggled from Lua on the menu map). First read the menu level/camera class names (UEVR log / UObjectHook) before proposing a change. Low priority until OpenXR works.
- [ ] **Item-selection marker offset and inverted** (user 23:48, OpenXR run 00:43): the hover/selection marker sits "a little too high and too much to the right", and moving the mouse down makes it move up. Explanation (not yet proven): with `VR_DecoupledPitch=true` the eye view ignores the game camera's mouse pitch, but the marker is a screen-space widget placed by projecting the object through the *game* camera, then shown on the 2 m UI panel. Mouse down pitches the game camera down, the object projects higher on the flat screen, so the marker goes up while the world in the headset doesn't move. The static offset is the flat-screen projection not matching the eye's view of the panel. Proposed single change (after the SteamVR run of the current build): `VR_AimMethod=1` (Head/HMD; UEVR 1.05 enum: 0 Game, 1 Head/HMD, 2 Right Controller, 3 Left Controller, 4/5 Two Handed) so the game's aim/control rotation follows the head and stops diverging from the view. Expected: marker stops moving against the mouse; some static offset may remain (panel vs eye projection); mouse pitch no longer aims. Other options if it doesn't: a world-space marker via UEVR Lua/UObjectHook, or hide the marker and use a head reticle.
- [ ] **Injector runtime default overrides the profile**: UEVRInjector 1.05 writes its OpenXR/OpenVR radio into `Frontend_RequestedRuntime` at injection; with no saved settings it picks OpenVR, which starts SteamVR. Hit on both runs 2026-11-27 (00:17 and 00:25). Fixed 2026-11-27: OpenXR saved in this injector's user.config, run-vr.ps1 sets it every run; OpenXR runs 00:28, 00:43, 00:55 all requested openxr_loader.dll (check-run.ps1 runtime-request PASS).

## Crash ledger

| Date | Signature (module+offset or error ID) | Run | Build and settings | Doing what | Linked issue |
|---|---|---|---|---|---|

## Log

### 2026-11-27 Claude (repo thread): git + GitHub set up

- Folder is now a git repo, remote `origin` = https://github.com/MasterRoshiHehe/Voices-of-the-Void-VR (public). `main` = LICENSE (MIT, already on GitHub) + README; `dev` = everything else via `feature/repo-setup`. The shared folder is checked out on `dev` and must stay there.
- Workflow in `AGENTS.md` "Git workflow": commit with `scripts\git-feature.ps1` (private index, never touches files on disk, so threads don't clobber each other), merge feature branches into `dev`, never push `main` without the user.
- `.gitignore` excludes tools\ (UEVR 1.05, OpenVR SDK, mirror-capture build), .venv, logs, runs, dumps, archives (kit-setup.tgz), game files. README documents fetching UEVR (zip SHA-256 recorded) and building the mirror capture.

### 2026-11-27 Claude (runtime thread): both-runtime checks, launcher hardening

- **`scripts\check-run.ps1 <run folder>`**: one PASS/FAIL/UNSURE line per check and a `VERDICT` line, written to `<run>\verdict.txt` (exit 0/1/2). Checks: UEVR requested the runtime the run wanted; that runtime came up (OpenXR: `OpenXR system Name`; OpenVR: `[OpenVR.cpp` / overlay lines); DirectX 11 hooked; OpenXR runs didn't start SteamVR; game exited; no new crash folder; launcher cleanup finished; SteamVR runs put the OpenXR default back; eyes (SteamVR: share of same-frame pairs passing `frame_check.py --reject <SteamVR idle frame>`; OpenXR: always UNSURE, the headset/user decides). Refuses to judge a run that is still in progress (a false FAIL on the live 00:55 menu run came from me running it too early; regenerated after it ended: INCONCLUSIVE, all log checks PASS). `run-vr.ps1` now calls it at the end of every run.
- **`scripts\runtime-matrix.ps1 [-Recheck]`** writes `checklists\runtime-matrix.md`: latest verdict per feature x runtime, all runs, and a hand-kept "Human checks" table (seeded with the two OpenXR confirmations). Rule: a feature is verified on OpenXR via that human table, on SteamVR via automated eye checks (plus feel in the headset).
- **`run-vr.ps1` changes:** `-Feature <name>` (logged, used by the matrix; other threads please pass it); `logs\.active-run.json` marker while a run owns the game, and the next run (or dry run) recovers an unfinished one: copies the missed UEVR logs into its folder, restores OpenXR in the profile + this injector's radio if it was a SteamVR run, notes it in that run.txt. Fixes the cleanup gap from closing the .bat window early (00:25 and 00:28 runs). SteamVR runs: background both-eye mirror snaps (`-EyeCaptureFirstDelaySeconds 30`, `-EyeCaptureEverySeconds 20`, `-EyeCaptureMax 30`, 0 = off) into `<run>\eyes\`; after exit a reject snap of SteamVR's idle view, then frame_check per pair into `eyes\verdicts.txt`; SteamVR is closed afterwards if the run started it (`-LeaveSteamVR` to keep it). OpenXR runs log `SteamVR during run: not-running|was-already-running|started`.
- **Mirror tool:** `snap` now reads left, right, left again and retries (up to 20) until both eyes come from one frame; prints `consistent`/`tries`/clock, exit 3 if never consistent. Addresses the 4 mismatched pairs of the first run (pairs straddling a new frame during head movement; that cause is now the leading explanation, not yet proven). Rebuilt `tools\mirror_capture_build\openvr_mirror_capture.exe` (edited the kit copy in `.agents\skills\vr-mod-test-harness\scripts\mirror_capture\`). Not yet run against SteamVR.
- **Launchers:** all four `.bat` files (repo root and **game folder** `F:\Games\Voices of the Void\Play-VOTV-VR.bat` / `Play-VOTV-VR-SteamVR.bat`) now print "Leave this window open: it copies the logs and resets the VR settings after the game closes."
- **Tests (no game launched):** at 00:57 (game not running, but inside the menu thread's 00:54-01:30 claim, which I hadn't seen yet; sorry) `-Runtime OpenVR -DryRun` set and restored OpenVR->OpenXR; a fake unfinished SteamVR run marker plus an OpenVR profile runtime was recovered by a plain `-DryRun` (profile back to openxr, marker removed, recovery line written). Final state same as before; user's E: injector settings hash unchanged (D212DAB9). Test folders deleted. Parse-checked under PS 5.1.
- **Gaps:** eye capture, reject snap and SteamVR close are untested until the SteamVR baseline run. Next: SteamVR baseline (`Play-VOTV-VR-SteamVR.bat -Feature baseline`) once the menu thread releases the game, needs VD connected and the user in the headset.
### 2026-11-27 Claude (menu thread): Lua error fixed (run 00:55)

- Run `logs\2026-11-27_00-55-47` (OpenXR): UEVR ran `votv_menu_camera.lua` and it stopped at load with a blocking popup `sol: runtime error: ...votv_menu_camera.lua:12: attempt to call a nil value (field 'getenv')`. UEVR 1.05's Lua has no `os.getenv` (and no `io` to rely on); the menu-camera code never ran, so the run says nothing about the hypothesis.
- Fix: settings read through UEVR's `fs.read("$scripts/votv_settings.txt")` (the `$scripts/` prefix is how the user's other UEVR profiles' scripts use `fs`); no `os.*`/`io.*` left; callback registration and every tick wrapped in `pcall`, errors go to the log as `[votv] ... error` lines instead of a dialog. Checked: syntax (lupa, Lua 5.4) and a stub smoke test with `os`/`io` = nil (loads, ticks, logs). Real UEVR API calls still untested in game.
- Note for whoever owns `verdict.txt`: in this run folder it reports FAIL for runtime-request, rhi, game-exit and cleanup, but `run.txt` and `uevr_log.txt` there do have those lines (`UEVR requested runtime: openxr_loader.dll`, `game exited`, `logs in ...`). It looks like it ran before the cleanup finished.

### 2026-11-27 Claude (controls thread): bindings read, controller layout proposed

- Read the game's bindings: user `Input.ini` (80 action mappings; rewritten by the game each start from `keybinds.sav`) and the pak's `[/Script/Engine.InputSettings]` block (read in place, nothing copied). **The game has no gamepad mappings and no axis mappings**; movement is digital W/A/S/D actions, look is presumably raw mouse axis events. So UEVR's pad emulation can't drive it; the controllers must send the game's keyboard/mouse keys.
- `CONTROLS.md` created: action inventory by context, proposed Quest 3 layout (right-hand aim, buttons send the key bound to each action so on-foot and ATV contexts both work), integration route (UEVR Lua reads controllers, `PlayerController.InputKey/InputAxis` sends keys; SendInput fallback), and the first three experiments. **Waiting on the user's OK** before building. Game not launched; profile not touched (the menu-camera thread is sharing it).

### 2026-11-27 Claude (menu thread): main-menu camera probe + aspect fix, ready to test

- Plan change (user 23:51): stage B goes straight to motion controllers; a separate thread owns controllers (bindings dump, CONTROLS.md, hand aim via UEVR aim method, button mapping, laser pointer). **The head-aim (`VR_AimMethod=1`) proposal for the selection marker is dropped**; hand aiming replaces it. Notes for the controller thread: the selection marker is screen-space and placed through the game camera (see Open issues); with right-controller aim the game's trace should follow the hand, but the marker on the 2 m UI panel will still be a flat projection, so check it on the first controller run. UEVR 1.05 aim enum: 0 Game, 1 Head/HMD, 2 Right Controller, 3 Left Controller, 4 Two Handed (Right), 5 Two Handed (Left). No controller work was started here.
- This thread owns the main menu: (1) cross-eye/mirroring, (2) a visible cursor/pointer there, (3) the menu as a real 3D space with the black borders turned into a soft vignette (user 23:50: the menu is in-game 3D, keep it 3D; can't see the mouse in the menu).
- **Change under test:** `profile\VotV-Win64-Shipping\scripts\votv_menu_camera.lua` (UEVR Lua, menu-specific, no config.txt change). Every second it logs view-target changes (actor, camera manager FOV and default constraint, each CameraComponent/CineCameraComponent's `bConstrainAspectRatio`, `AspectRatio`, `FieldOfView`) as `[votv]` lines in UEVR's log.txt, and with `menu_unconstrain_aspect=1` in `scripts\votv_settings.txt` (live setting, default 1) sets `bConstrainAspectRatio=false` on any camera that has it, logging each once. Hypothesis: the menu camera letterboxes (black borders) and UEVR's stereo projection breaks with a constrained aspect. Lua syntax checked with lupa (Lua 5.4) only; UEVR API calls are untested.
- `run-vr.ps1`: copies the repo's `profile\<exe>\scripts\*` into the UEVR profile's `scripts` each run (adds/overwrites only). Dry run OK.
- Test: OpenXR first (`Play-VOTV-VR.bat`): look at the main menu (still cross-eyed? borders gone?), then the log tells which camera it is. If the write fails or nothing is constrained, the hypothesis is wrong and the log still names the menu camera. Then the same on SteamVR.

### 2026-11-27 Claude: SteamVR parallel-test launcher

- User requirement (23:42): keep the game playable on both OpenXR and SteamVR, test both in parallel. Rule added to AGENTS.md (OpenXR via VD primary/default, SteamVR parallel; verify each feature on both).
- `run-vr.ps1 -Runtime OpenXR|OpenVR` (default OpenXR). OpenVR sets the profile runtime and this injector's radio for that run only; the finally block restores OpenXR in both (after the injector closes and after the run's config is copied). Only this injector's settings file is touched (never `E:\Tools\VR\UEVR`). The SteamVR-runtime warning only applies to OpenXR runs.
- **Game folder change:** added `F:\Games\Voices of the Void\Play-VOTV-VR-SteamVR.bat` (calls the dev script with `-Runtime OpenVR`); also `Play-VOTV-VR-SteamVR.bat` in the repo root.
- Dry-run tested after the HUD run ended (00:47): game-folder `Play-VOTV-VR-SteamVR.bat -DryRun` set profile runtime + injector radio to OpenVR, stopped before launch, then restored both to OpenXR (checked in the files); the user's E: injector settings hash unchanged (d212dab9...). Normal `Play-VOTV-VR.bat -DryRun` still OpenXR. Not yet run with the game.
- HUD-fix run `logs6-11-27_00-43-09` (00:43-00:47): OpenXR via VD, `VR_DecoupledPitchUIAdjust=false` in effect, clean exit and full log copy. **User 23:48: "the HUD did stay put": HUD pitch fix confirmed on OpenXR.** Item selection still works.

### 2026-11-27 Claude: OpenXR run playable; HUD pitch change for next test

- Run `logs\2026-11-27_00-28-34` (00:28-00:39): **OpenXR via Virtual Desktop confirmed**: run log `runtime wanted: openxr_loader.dll`, `injector radio already OpenXR`, active runtime `virtualdesktop-openxr.json`; UEVR log `Requested runtime: openxr_loader.dll`, `Initializing OpenXR`, extensions from VDXR; no SteamVR process. D3D11. No crash. The .bat window was closed before cleanup again, so I copied the UEVR log/config afterwards.
- **First headset look done** (user 23:41): "more or less in the most basic of ways playable in vr, it looks great and runs great, the only issue being that my HUD follows my mouse on the Y axis". Saved the game outside the base.
- HUD issue: with `VR_DecoupledPitch=true`, mouse pitch moves the game camera's pitch separately from the head; `VR_DecoupledPitchUIAdjust=true` (which I set in the baseline) makes the UI panel follow that decoupled game pitch. Key confirmed present in UEVR 1.05's backend strings. **One change for the next test:** `VR_DecoupledPitchUIAdjust=false` in the baseline and the AppData profile. Revisit criterion: if the crosshair/aim and HUD panel now disagree badly when looking up/down, consider aim settings instead.

### 2026-11-27 Claude: injector pinned to OpenXR (no SteamVR), second run logs

- Second run 00:25:22 (`logs\2026-11-27_00-25-22`) also requested `openvr_api.dll`. Cause: the AppData profile still held `openvr_api.dll` from run 1, the script read the runtime from there, and the injector had no saved settings. **Side effect fixed:** that script version set the radio to OpenVR in *every* `UEVRInjector_Path_*` settings file, including the user's other UEVR install (`E:\Tools\VR\UEVR`); I set that file back to OpenXR=True/OpenVR=False at 00:26. The run's cmd window was closed before cleanup, so I copied the UEVR log/config into that run folder afterwards. The user also saw a stray second injector window at ~00:25: mine (started to inspect the UI while their run was live; I hadn't checked the process list). Killed; their game was not touched. Lesson: check `tasklist` before starting anything game-related.
- **Injector settings now saved:** with the game closed, selected the OpenXR radio in the injector via UI Automation and closed it with the window's Close pattern; it wrote `%LOCALAPPDATA%\praydog\UEVRInjector_Path_ykqoahobqtdhw1tefpiz54ewenoq31mv\1.0.0.0\user.config` with OpenXRRadio=True, OpenVRRadio=False.
- **run-vr.ps1:** the runtime comes from the repo baseline and is written back into the AppData profile each run; only this injector's settings file (`-InjectorSettingsDir`) is touched; refuses to inject if OpenXR is wanted and that file is missing; logs the active OpenXR runtime (HKLM, currently Virtual Desktop's `virtualdesktop-openxr.json`) and warns if SteamVR; new `-DryRun` runs all pre-launch checks without launching. `-DryRun` verified: profile runtime reset to openxr, radio already OpenXR, active runtime VDXR. Missing-settings refusal verified with a fake folder name.
- User preference recorded in AGENTS.md: no SteamVR.

### 2026-11-27 Claude: first headset run (run started 00:17 via Play-VOTV-VR.bat), cross-eyed / mirrored-yaw report

- User: "the two eyes are showing something different, I am very cross eyed" and (via coordinator) "looking left/right is currently mirrored".
- **Runtime was OpenVR, not OpenXR.** UEVR log: `Requested runtime: openvr_api.dll`; the profile's `Frontend_RequestedRuntime` was rewritten to `openvr_api.dll` by the injector (new injector path has no saved radio state, default OpenVR). UEVR showed its "VD Warning" dialog (Virtual Desktop detected with OpenVR). SteamVR (vrserver) was running. RHI: D3D12 hook failed, D3D11 used (as pinned).
- Built the harness mirror tool (`tools\mirror_capture_build\openvr_mirror_capture.exe`, OpenVR SDK v2.15.6 headers/lib/dll fetched from ValveSoftware/openvr into `tools\openvr-sdk\`, MSVC BuildTools 18 + Ninja). 15 non-black snaps of both eyes, 00:21:06-00:21:39, `runs\2026-11-27_first\poll\` (user in the tutorial room).
- **Static stereo geometry looks correct** (horizontal cross-correlation between eyes per band): 10 of 15 snaps match at +256 px for far content and +264..274 px for the near floor (eye width 1036). Expected far offset from the asymmetric per-eye FOV (UEVR log: left 1.2387/-0.7552, right mirrored) is 0.2425w = 251 px; near content has *more* offset than far, which is the right sign (eyes not swapped), and +20 px at ~1.7 m matches a ~63 mm IPD (scale about right). Images are not left-right mirrored (text/HUD reads normally). **4 snaps (s000, s008, s012, s013) have eyes that don't match at all** (corr 0.13-0.31), all during head movement; cause unknown: either the two eyes come from different frames/poses in the headset, or my snap reads the two mirror textures a frame apart. Not settled.
- HUD (hotbar, markers) is drawn inside the eye images; in s000 its offset between eyes was less than infinity (eyes would need to diverge). Unconfirmed, one frame.
- Not reproduced yet: the mirrored head yaw (a still image can't show it). Needs either the user's exact description (real head turn vs stick) or a stream capture with HMD pose.
- Prepared, not yet tested: `run-vr.ps1` now sets the injector's saved radio to match the profile runtime before injecting, closes the injector gracefully (so it saves user.config), and logs/warns the runtime UEVR actually requested.
- Next (one change): rerun with OpenXR (VDXR) only. Gap: the SteamVR mirror tool can't see a VDXR session.

### 2026-11-27 Claude: double-click launchers (user asked for a .bat)

- `Play-VOTV-VR.bat` in the repo root: runs `scripts\run-vr.ps1` via `powershell -NoProfile -ExecutionPolicy Bypass`, passes extra args through, pauses at the end so messages stay visible.
- **Game folder change:** added `F:\Games\Voices of the Void\Play-VOTV-VR.bat` (same, but calls the dev-folder script by absolute path). Remove it to undo; nothing else in the game folder changed.
- Checked both with `-GameDir X:\nope` (no launch): each reaches the script body and stops at the intended missing-game-dir error.

### 2026-11-27 Claude: run-vr.ps1 fix (first user run failed before launch)

User ran the script from cmd (PowerShell 5.1): `Join-Path : Cannot bind argument to parameter 'Path' because it is an empty string` at the `$UevrDir` default. Cause: `$PSScriptRoot` is empty in param defaults under 5.1 `-File`. Reproduced with `powershell -File run-vr.ps1 -GameDir X:\nope` (same error), fixed by resolving `$UevrDir` in the body from the script's own path, rerun of the same command now reaches the body and stops at the intended missing-game-dir error. No PS7-only syntax left (grep for `??`, `?.`, `&&`, `||`, ternary: none). Game not launched.

### 2026-11-27 Claude: user allows changing the game folder

User (project thread, 2026-11-26 23:03 UTC): "feel free to change the game as needed, it is free and I can easily download a new copy of it". So agents may write into `F:\Games\Voices of the Void` when a step needs it (e.g. UE4SS next to the exe, engine ini overrides). Still apply: record every file added/changed there in this log, keep the launcher's cleanup, and keep game files out of the repo. Stage A needs no game-folder change (UEVR injects; profile is in AppData).

### 2026-11-27 Claude: stage A prepared (UEVR downloaded, run script, profile)

- Deleted leftover `kit-setup.tgz`. Added `tools/` and `logs/` to `.gitignore`.
- **UEVR 1.05** (latest stable, GitHub release `1.05` of praydog/UEVR, published 2024-11-16), asset `UEVR.zip` (7,399,455 bytes), SHA-256 `af4f2f91306802d7ee4e8497d483a547ac8e9a3067dbafb81324100524215d3c`, matches the release's `UEVR.zip.sha256`. Extracted to `tools\UEVR\1.05\UEVR\`; `revision.txt` = `1a810f69fe4cab82b352c574763959d4390b84ce`. (The user already has a UEVR nightly profile set from other games under `%APPDATA%\UnrealVRMod`; untouched.)
- Python venv created (`.venv`, Python 3.14.5, numpy 2.5.5, Pillow 13.0.0).
- VOTV user config read (RESEARCH.md §2): no RHI or AA-method override locally; AA quality High; RHI pinned by `-d3d11` in the run script.
- **Injector scripting:** UEVRInjector 1.05 has a single command-line flag, `--attach=<process name>` (read from the exe's strings; no runtime flag, no `--help`). Runtime comes from the profile's `Frontend_RequestedRuntime` and the injector's OpenXR/OpenVR radio. Unverified: whether the radio follows the profile on `--attach`; check on the first run.
- **`scripts\run-vr.ps1`**: refuses to start if the game or injector is already running; banner with game exe SHA-256 (warns if not the RESEARCH.md §0 build) and UEVR revision; seeds the AppData profile from the repo baseline only if missing (`-ResetProfile` to force) so UEVR menu tweaks persist; launches `VotV.exe -d3d11` (`-LaunchExe Shipping` for the shipping exe); bounded waits for process (90 s) and window (120 s), then `-InjectDelaySeconds` (15) and `UEVRInjector --attach=VotV-Win64-Shipping`; confirms "UnrealVR entry" in a fresh UEVR log.txt (60 s bound); waits for exit (optional `-MaxRunMinutes`); always kills the injector and copies UEVR log/config/cameras/imgui and any new game logs into `logs\<timestamp>\`; reports new crash folders without copying dumps. `-NoInject` gives a flat A/B run. Parse-checked only; **not run yet**.
- **Profile `config.txt`** (baseline in `profile\VotV-Win64-Shipping\config.txt`, copied to AppData; all other keys left at UEVR defaults):
  - `Frontend_RequestedRuntime=openxr_loader.dll`: OpenXR (RESEARCH.md §4), VDXR on Virtual Desktop.
  - `VR_RenderingMethod=0`: Native Stereo, both eyes same frame. Fallback if shadows/effects break: `1` (Synchronized Sequential; `VR_SyncedSequentialMethod=1` preset).
  - `VR_UncapFramerate=true`, `OpenXR_ResolutionScale=1.0`: no frame cap from the game, native resolution until measured.
  - `VR_EnableGUI=true`, `UI_OverlayType=0` (flat quad), `UI_Distance=2.0`, `UI_Size=2.0`, offsets 0: game HUD/menus on a floating panel 2 m ahead (stage A request). `UI_FollowView=false`: comfort rule, UI never re-follows the player. `VR_DecoupledPitchUIAdjust=true`: keep the panel level when decoupled pitch is on.
  - `VR_DecoupledPitch=true`: game pitch doesn't tilt the horizon (comfort).
  - `VR_AimMethod=0`: game/head aim; hand aiming is stage B. `VR_ControllersAllowed=true`: Touch controllers emulate an XInput gamepad, i.e. the existing controls.
  - `VR_SnapTurn=false`, `VR_RoomscaleMovement=false`, `VR_WorldScale=1.0`: no new locomotion in stage A; scale to judge in the headset.
  - `FrameworkConfig_MenuOpen=false` / `RememberMenuState=false`: build starts in the mode under test, no UEVR menu in the face. `FrameworkConfig_LogLevel=2` (info), `LuaLoader_LogToDisk=true`: logs for us. `UObjectHook_EnabledAtStartup=false`.
- Nothing in the game folder was touched. Next: user starts Virtual Desktop + Quest 3, runs the script; then check UEVR log (RHI, runtime, stereo mode) and both eyes with `frame_check.py`, then a first five-minute headset look.

### 2026-11-26 Claude: absorbed VR-MOD-HANDOFF.md

Lessons from the Sims 4 VR project folded into RESEARCH.md §8 and AGENTS.md rules (UEVR stays the core; process, observability, UI and comfort rules adopted).

### 2026-11-26 Claude: kit set up, research pass

Kit Joe975/vr-modding-with-agents @ 07424c2 copied in (skills to .agents/ and .claude/). Venv not created: the setup ran from a Linux shell, so the Windows venv is left for the human (above). No git repo in the folder yet. RESEARCH.md written; game exe SHA-256 5e690d8f…f6cc (2026-11-11), UE 4.27.2. Next: human answers, then the first flat-screen experiment (RESEARCH.md §6).
