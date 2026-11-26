# Voices of the Void VR

**Unofficial, non-commercial fan mod. Not affiliated with or endorsed by MrDrNose or the Voices of the Void project.**

A VR mod for [Voices of the Void](https://mrdrnose.itch.io/votv) (Unreal Engine 4.27). It is built on
[UEVR](https://github.com/praydog/UEVR) by praydog: UEVR does the stereo rendering and headset
tracking, and this repo adds a tuned UEVR profile, Lua scripts and a launcher for this game.

Status: early development. Expect rough edges.

## Features

- Stereo VR through UEVR 1.05 (Native Stereo), first-person view driven by the headset.
- Two runtimes, every feature:
  - **OpenXR** (default), for example Virtual Desktop's VDXR runtime.
  - **SteamVR / OpenVR**, through a separate launcher.
- Tested on Quest 3 over Virtual Desktop (RTX 4080 Super, Windows 11). Other headsets and GPUs are untested.
- Single-player. Co-op (Multivoid) is untested.

## What you need

- Voices of the Void (PC). Tested on the 2026-11 build; other builds may not work.
- A PC VR setup: an OpenXR runtime (Virtual Desktop, Oculus/Meta Link, SteamVR...) and/or SteamVR.
- [UEVR 1.05](https://github.com/praydog/UEVR/releases/tag/1.05) (not included in this repo).
- Windows 10/11 with PowerShell (built in).

## Install

1. Download or clone this repo, for example to `F:\Moddings\VOTV\Claude`.
2. Download `UEVR.zip` from the [UEVR 1.05 release](https://github.com/praydog/UEVR/releases/tag/1.05)
   and extract it so that `tools\UEVR\1.05\UEVR\UEVRInjector.exe` exists inside the repo folder.
   The zip we tested has SHA-256 `af4f2f91306802d7ee4e8497d483a547ac8e9a3067dbafb81324100524215d3c`
   (check with `Get-FileHash UEVR.zip`).
3. If your game is not installed at `F:\Games\Voices of the Void`, pass `-GameDir "<your game folder>"`
   to the launcher (see below).

The mod does not modify or replace any game files. The launcher seeds the UEVR profile from
`profile\VotV-Win64-Shipping\` into `%APPDATA%\UnrealVRMod\VotV-Win64-Shipping\`.

## Launch

1. Start your VR runtime and connect the headset (for Quest 3: start Virtual Desktop and connect).
2. Double-click one of:
   - `Play-VOTV-VR.bat`: OpenXR (default).
   - `Play-VOTV-VR-SteamVR.bat`: SteamVR/OpenVR. UEVR starts SteamVR; the OpenXR default is restored afterwards.
3. The launcher starts the game with `-d3d11`, waits for its window, injects UEVR and copies the
   logs to `logs\<timestamp>\` when the game exits.

Useful options (append to the `.bat`, or run `scripts\run-vr.ps1` directly):

| Option | What it does |
| --- | --- |
| `-GameDir "<path>"` | Game install folder |
| `-InjectDelaySeconds N` | Wait longer before injecting (default 15) |
| `-Runtime OpenXR\|OpenVR` | Pick the runtime |
| `-ResetProfile` | Re-seed the UEVR profile from this repo |
| `-NoInject` | Flat run, same launch path |
| `-DryRun` | Run all pre-launch checks without launching |

## Developer tools (optional)

These are only needed for the automated test harness. None of them are committed.

- **Python venv**: `py -3 -m venv .venv` then
  `.venv\Scripts\pip install -r .agents\skills\vr-mod-test-harness\scripts\requirements.txt`.
- **SteamVR mirror capture** (both-eye checks on SteamVR runs): get the
  [OpenVR SDK v2.15.6](https://github.com/ValveSoftware/openvr/releases/tag/v2.15.6) into
  `tools\openvr-sdk\v2.15.6\`, then build
  `.agents\skills\vr-mod-test-harness\scripts\mirror_capture` with CMake (MSVC, Ninja):
  `cmake -S .agents\skills\vr-mod-test-harness\scripts\mirror_capture -B tools\mirror_capture_build -G Ninja -DOPENVR_SDK_DIR=<repo>\tools\openvr-sdk\v2.15.6`
  and `cmake --build tools\mirror_capture_build`.

Project notes for contributors (and the AI agents working on this) are in `AGENTS.md`,
`STATUS.md`, `RESEARCH.md` and `CONTROLS.md`.

## Credits and licences

- This repo's own code and docs: [MIT](LICENSE).
- [UEVR](https://github.com/praydog/UEVR) by praydog is a separate download under its own terms;
  this repo contains none of its code.
- Voices of the Void is by MrDrNose. No game files or game code are included here.
