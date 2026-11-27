# Voices of the Void VR: research pass

Date: 2026-11-26. No mod code was written in this pass. Every claim has a source; "checked locally" means it was read from the install at `F:\Games\Voices of the Void`.

## 0. The game build we're targeting

- `VotV/Binaries/Win64/VotV-Win64-Shipping.exe`, modified 2026-11-11, 86,075,392 bytes, SHA-256 `5e690d8f62fe6ce5b9d46815dd05ced45e52a4f110e91f0b6248bbacbe96f6cc` (checked locally).
- One pak, `VotV-WindowsNoEditor.pak` (8.7 GB), modified 2026-11-11 (checked locally).
- Engine string in the exe: `++UE4+Release-4.27-CL-18319896`, i.e. Unreal Engine 4.27.2 (checked locally).
- Public version: the latest stable line is Alpha 0.9.0, build `a090n` ([allthings.how, updated 2026-09-08](https://allthings.how/voices-of-the-void-0-9-0-n-what-changed-in-the-latest-stable-build/)); Multivoid also targets "0.9.0n" ([install.md](https://github.com/VOTV-MP/Multivoid/blob/main/docs/install.md)). The local exe is newer than that article, so the exact in-game version string is still to confirm from the main menu.
- The install is vanilla: no UE4SS, no UEVR files, no `LogicMods` folder (checked locally).

## 1. Existing VR work and frameworks

| Source | What it is | Use it? |
|---|---|---|
| Old Reddit guide "VR mode guide for VOTV (updated 0.9c/0909b)" ([link](https://www.reddit.com/r/Voicesofthevoid/comments/1q4c0eb/vr_mode_guide_for_votv_updated_09c0909bvr/)) | Could not be read: Reddit blocks automated access. Its companion Drive file is **`VotV-Win64-Shipping.zip`** ([Drive](https://drive.google.com/file/d/1CaGqgJiAiz150FrbfqWrHDdsIEJl9Wb9/view)), i.e. a replacement game exe. | Don't use the exe (see "What's outdated" below). Paste the guide text here to finish this row. |
| YouTube "UEVR Guide: Voices of the Void VR (0.9)", RedTort, 2026-02-16 ([video](https://www.youtube.com/watch?v=NndMVQHcpGM)) | Says VOTV 0.9d runs in VR with stock UEVR "in 1 minute". No exe swap mentioned in the description. | Confirms UEVR works on this game. |
| itch.io threads ([2024](https://itch.io/t/4077990/chance-of-a-built-in-vr-mode), [recent](https://itch.io/post/12820421/view-in-topic)) | Players run it with UEVR (+ AutoHotkey for controls). A commenter (not the dev) says MrDrNose looked at VR but paused for lack of a headset. | No official VR mode exists or is announced. |
| **UEVR** ([praydog/UEVR](https://github.com/praydog/UEVR)) | Universal UE 4.8 to 5.4 VR injector. Latest stable 1.05 (published 2024-11-16, still the latest stable on 2026-11-27; adds full Lua API, UObjectHook "Attach HMD"). Nightlies at [UEVR-nightly](https://github.com/praydog/UEVR-nightly/releases). Modes: Native Stereo (same frame), Synchronized Sequential, AFR. OpenXR or OpenVR. | **Yes: build on this.** |
| **RE-UE4SS** ([repo](https://github.com/UE4SS-RE/RE-UE4SS)) | The standard VOTV mod loader (Lua, Blueprint, C++ mods), packaged as Unreal Shimloader on Thunderstore ([wiki](https://questwalker.github.io/votv-modding-wiki/docs/modding-intro)). | Yes, for gameplay-side helpers that UEVR Lua can't reach easily. |
| elliotttate/vrframework ([repo](https://github.com/elliotttate/vrframework)) | Engine-agnostic REFramework-derived core plus a 17-part guide; its reference ports are RE Engine, Creation Engine 2, Anvil and FH5. | **Reference reading only.** UEVR already is the UE equivalent; rebuilding injection, D3D hooks and stereo for UE4.27 would waste months. |
| Joe975/vr-modding-with-agents | This kit: process, test harness, controls design. | Yes, it's installed here. |

### What's outdated in the old guide

1. **It swaps the game exe.** The Drive file is a replacement `VotV-Win64-Shipping.exe`. An exe built for 0.9.0 won't match the current pak (2026-11-11), so it will crash or misbehave, and every game update overwrites it again. It is also an unsigned binary from an unknown source. Current UEVR injects into the stock exe, so no swap is needed.
2. **Older UEVR.** A 0.9.0-era guide predates UEVR 1.05's Lua API and UObjectHook improvements (HMD attach, offset sliders), which replace most AutoHotkey/ini hacks.
3. **Profile tied to the old build.** Any UObjectHook paths and cvars in it must be re-checked against the current build (Blueprint class names can change between alphas).

## 2. Loading, graphics API, publisher guidance

- **Loading:** UEVR injects at runtime (UEVRInjector, pick `VotV-Win64-Shipping.exe`, Inject); a profile folder named after the exe holds config, UObjectHook state and Lua scripts ([UEVR README](https://github.com/praydog/UEVR)). UE4SS goes next to the exe in `VotV/Binaries/Win64` ([wiki install](https://questwalker.github.io/votv-modding-wiki/docs/installing-mods/install-manual)).
- **Graphics API:** D3D11 and D3D12 RHIs are both in the exe (checked locally). Default unknown: check `%LOCALAPPDATA%\VotV\Saved\Config\WindowsNoEditor\Engine.ini` or launch with `-d3d11` to pin it. UEVR supports both; D3D11 is the safer start.
- **User config read 2026-11-27** (`%LOCALAPPDATA%\VotV\Saved\Config\WindowsNoEditor\`, read only): no RHI override anywhere (`Engine.ini` holds only `[Core.System]` paths; `Hardware.ini` and `Scalability.ini` are empty), so the RHI comes from the project's DefaultEngine.ini inside the pak; UE4.27's Windows default is D3D11 unless the project sets `DefaultGraphicsRHI`, still unconfirmed. `run-vr.ps1` pins it with `-d3d11`. AA: `GameUserSettings.ini` has `sg.AntiAliasingQuality=2` (High); the AA *method* (TAA/FXAA, `r.DefaultFeature.AntiAliasing`) isn't overridden locally, so it's the project default (unknown; expect TAA). Other: ResolutionQuality 100, Shadow 1, PostProcess 1, Shading 0, fullscreen mode 1 at 2048x1152, VSync off, no frame cap. No `Saved\Logs` files (shipping build), so the log can't confirm the RHI either; check UEVR's log.txt after the first run.
- **Game folder (user decision, 2026-11-26):** the user allows modifying the install as needed (free game, easy to re-download). Log every change in STATUS.md.
- **No built-in HMD plugin:** the exe has no OpenXRHMD/SteamVR/Oculus module strings (checked locally), so UEVR's "nullify VR plugin" is not needed.
- **Publisher guidance:** No official modding policy was found. The game is a free, single-player itch.io alpha by MrDrNose with an active mod scene (Thunderstore, wiki) and no anti-cheat found. Unresolved: whether redistributing a UEVR profile needs anything from the dev (normally not, since profiles contain no game files). **Your call:** confirm you're happy with single-player scope and personal/community sharing.

## 3. Camera, projection, frame boundary

UEVR owns all three for UE4: it hooks the engine's stereo rendering device and `CalculateStereoViewOffset`/projection, and the frame boundary via the RHI. Our work is on top: camera attachment (pawn/camera manager), FOV-dependent fields, and UObjectHook attachments for hands and held items. The VOTV-specific bits to find with UEVR's UObjectHook/Lua object browser (or UE4SS live view):

- Player pawn class and its camera component (first-person, so HMD drives camera rotation).
- Held-item / hand mesh components to attach to motion controllers.
- Post-process and effects that fight VR: screen-space vignette/blur, film grain, the camera "lean"/head bob, and TAA (VR TAA smear; try FXAA via `r.DefaultFeature.AntiAliasing`, cvar present in the exe).

## 4. Runtime and stereo

- **Runtime: OpenXR** (UEVR supports both). Switch to OpenVR only if your headset/setup needs it.
- **Stereo: Native Stereo (same-frame) first.** UE4.27 is UEVR's best-supported range. Fallback: Synchronized Sequential if Native Stereo shows broken shadows/effects. AFR is last resort.

## 5. Gameplay contexts and interaction scope

From play knowledge, to be confirmed by dumping input bindings (`Input.ini` / project settings in pak, UE4SS live view):

- On foot (walk, sprint, crouch, jump, lean), physics grab/throw/rotate of objects, inventory and hotbar, computer/terminal screens (signal processing, ATV, laptop), driving the ATV, sleeping, eating/drinking, a few weapons/tools (e.g. kerfur interactions, flashlight).
- Integration routes: UEVR's gamepad emulation (motion controllers to XInput), UEVR Lua for aim/trace from controller, UE4SS Lua to call game Blueprint functions (grab, use) directly.
- Key VOTV-specific needs: interacting with in-world computer screens (pointer from hand), physics grabbing (aim from hand, not head), the ATV (seated/vehicle context).

**User's plan (2026-11-26):** stage A first (stereo + head tracking, existing controls, HUD on a floating panel), then stage B (motion controllers, hand aiming), then maybe stage C (full hands-on interaction). One step at a time.

## 6. First experiment (flat screen)

Install UE4SS (experimental-latest), run a Lua script that offsets the player camera by a known amount, and check the scene shifts by the predicted fraction of the screen. Then, separately, inject UEVR into the stock exe with OpenXR + Native Stereo and capture both eyes via SteamVR mirror to confirm stereo works on this build.

## 7. Rendering baseline

- Baseline: D3D11, UEVR Native Stereo, FXAA or TAA-off, no vendor upscalers (none found in the exe).
- Evidence matrix: empty. Expected first row: RTX 4080 Super, Quest 3 via VDXR (and SteamVR), D3D11, Native Stereo. All combinations untested.
- Performance scenes to compare: base interior, outdoor at night with fog, around the base with many physics props.

## 8. Lessons carried over from the Sims 4 VR handoff (VR-MOD-HANDOFF.md, 2026-11-26)

What changes for VOTV because of it:

- **Hardware is known (assumed same rig):** Quest 3 over Virtual Desktop (VDXR OpenXR runtime), RTX 4080 Super, i7-13700K, Windows 11. Test both VDXR and SteamVR early; VDXR has no visibility mask, space warp or foveation, and `xrEndFrame` can stall 100+ ms when the stream backs up.
- **Why UEVR here and not a Sims4VR-style native DLL:** most of that project's six weeks went into things UEVR already does for UE4 (Present hook, OpenXR on the game device, camera override, per-eye FOV, pose-drawn-equals-pose-submitted, frame pacing). Native Stereo in UEVR is the "both real eyes every frame" mode the Sims project shipped only after trying four others. UEVR's code is all-rights-reserved (only `API.h` is MIT), so we use it as a tool and write plugins/Lua against its API; we don't copy its source.
- **Where custom work is still needed** (UEVR C++ plugin or Lua, UE4SS Lua): hand-aimed interaction, held items on hands, UI on its own layer, comfort options, logging. Sims lessons that apply directly: write camera *fields* not matrices (UEVR does), list everything that assumed one camera per frame (picking/line traces from the head, audio listener), per-eye exact FOV, negative mip bias if render scale drops.
- **Reverse engineering on UE4 is cheaper:** instead of Ghidra over the exe, use UE4SS's object/class dumps (CXX header and Lua type dumps) and FModel/UnrealPak to read Blueprint class and widget names from the pak. The handoff's "decompile rule" becomes: read the dumped class/Blueprint before implementing a hook, and note which classes were checked.
- **UI rule:** never crop the game's rendered UI. VOTV's UI is UMG widgets, so put widgets on their own quad/layer (UEVR can render UMG to a separate layer) or redraw from game data, with a crop fallback only for rare screens, flagged.
- **Observability before features (handoff §12):** UEVR already logs to its profile folder; add our own log with ms timestamps, a startup banner (mod version, game exe SHA-256, UEVR version), a "mark" button (screenshot + log marker), and a crash/flight record. The AI pulls logs from the PC itself; the player only says what they saw.
- **Process rules adopted:** one change per build and per test; builds start in the mode under test; game-closed check before installing; prove the cause from data before coding; headset result outranks logs; settings autosave on change; every tunable is a live setting.
- **Comfort defaults from the player:** haptics off, snap turn needs a full stick push, smooth turn on the display clock, UI never re-follows the player, sound always 3D, never change the game's clock.
- **Order of work (handoff §16, adapted):** UEVR stereo + logs → flat-to-VR check with marks → hand-aimed interaction → UI layer → comfort/perf polish → release hygiene (pin game build by exe hash, fail closed).
- The handoff's `reference/` companion folder was not included; ask if specific files (e.g. `vd-freeze-handoff.md`, `MARK-HANDOFF.md`) are needed.

## 9. In-game tuning menu: what each UEVR version allows (checked 2026-11-27)

Sources: local UEVR 1.05 headers (tools/UEVR/1.05, revision 1a810f69, plugin API 2.34); docs.uevr.io plugin and Lua
pages; github.com/praydog/UEVR master (lua-api/lib/src/ScriptContext.cpp, lua-api/examples/imgui_and_configs.lua,
examples/example_plugin/Plugin.cpp); github.com/praydog/UEVR-nightly releases.

- UEVR 1.05 (2024-11-16, our installed build): Lua has no `imgui`, no `on_draw_ui`, no file IO (confirmed in game:
  `votv_hands.lua:727 attempt to index a nil value (global 'imgui')`). The 1.05 C++ plugin API has no draw-UI hook either.
  A plugin can still draw its own Dear ImGui window: UEVR's example plugin creates its own ImGui context and draws it
  in `on_present` (desktop) and `on_post_render_vr_framework_dx11/dx12` (into the VR frame), feeding mouse/keyboard
  from `on_message`. In the headset that window has no pointer: it needs mouse input or our own controller navigation.
- UEVR nightly (Lua imgui/json/fs added 2025-04-28, commit 78a11df7; latest nightly-01143, 2026-08-30): Lua scripts get
  `uevr.sdk.callbacks.on_draw_ui(fn)` with `imgui.*` widgets drawn inside UEVR's own menu (usable in the headset with
  UEVR's menu pointer), plus `json.dump_file/load_file` and `io.open`, so a script can save presets itself.
- Mistake recorded: the first panel was written against the nightly Lua API while the install is 1.05.
- Options: (a) move to a UEVR nightly (in-game panel in the UEVR menu; everything built on 1.05 must be re-verified on
  both runtimes); (b) stay on 1.05 and render our own ImGui window from votv_controls.dll (Dear ImGui is MIT; UEVR's
  example code is all-rights-reserved, so written from scratch), with controller navigation; (c) desktop Hand-Tuner
  window (built, scripts/hand_tuner.py). Decision: pending the user.

## Unknowns to close

- Exact in-game version string; default RHI.
- The old Reddit guide's actual text (paste it).
- Confirm the headset/PC are the same as the Sims project (Quest 3, VD, RTX 4080 Super).
- Your intended experience (seated/standing, gamepad vs motion controls, HUD).
- Python on Windows for the kit's harness venv.
