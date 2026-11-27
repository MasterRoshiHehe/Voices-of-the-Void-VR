# Controls

Stage B: motion controllers (user decision 2026-11-26/27): aim and pick up with the right hand,
controller buttons mapped to the game's actions, physical keyboard kept for the in-game computers.
Laser pointer for menus comes later. Status of this file: **proposal, waiting for the user's OK**
(2026-11-27). Nothing below is built yet.

## 1. What the game actually has (read 2026-11-27, game exe SHA-256 5e690d8f…f6cc)

Sources, read only:

- `%LOCALAPPDATA%\VotV\Saved\Config\WindowsNoEditor\Input.ini`: 80 action mappings, rewritten by
  the game at every start (mtime matched the 00:44 run) from its own `keybinds.sav` (compressed,
  not decoded). So the in-game keybind menu is the source of truth, not hand edits to Input.ini.
- The pak's `[/Script/Engine.InputSettings]` block (found uncompressed at offset ~169.8 MB of
  `VotV-WindowsNoEditor.pak`; only read, nothing copied into the repo).

Findings that decide the design:

1. **No gamepad support at all.** Zero `Gamepad_*` action mappings in either file, and **no axis
   mappings**: the pak only has `AxisConfig` dead zones. Movement is four digital actions
   (`Forward`/`back`/`Left`/`Right` = W/S/A/D); mouse look is presumably raw `MouseX/MouseY` axis
   events in the player Blueprint (not yet checked in the Blueprint). So UEVR's built-in
   "controllers emulate an Xbox pad" does nothing useful here; it can at most nudge Slate/UMG menu
   focus (to neutralise).
2. **One key, many meanings by context.** E is `use`, `Up`, `atv_use`, `radar_zoomIn`; W/A/S/D drive
   on foot, on the ATV, and on the radar/coordinates computers; Escape is `Pause` and `dismount`;
   LeftShift is `Run`, `containerPut`, `atv_turbo`, `coord_quickScan`, `radar_resetView`; LeftAlt is
   `activateEquipment`, `Alt`, `atv_honk`, `coord_switchTarget`. The game picks the meaning by
   context, so sending the *key* reproduces every context for free.
3. UEVR 1.05 API gives us both controllers' poses, sticks, buttons (`on_xinput_get_state`,
   `get_joystick_axis`, `is_action_active`) and haptics, from Lua or a C++ plugin
   (`tools\UEVR\1.05\UEVR\include\uevr\API.h`).

4. **Checked in the player Blueprint** (2026-11-27, game-internals thread, pak read; details in
   `docs/GAME-INTERNALS.md` §8): mouse look is axis events `mouseX`/`mouseY` (bound in code) that
   call `AddControllerYawInput`/`AddControllerPitchInput`, plus `MouseWheelAxis`. `mainPlayer_C`
   handles these actions (pressed/released events): `drop`, `offhand`, `spawnmenu`, `alt`,
   `throwPath`, `run`, `dismount`, `cheatmenu`, `rotate`, `crouch`, `jump`, `inventory`, `noclip`,
   `forward`, `back`, `left`, `right`, `use`, `zoom`, `hotbar_1..9`, `superscreenshot`,
   `flashlight`, `quicksave`, `undo`, `ragdoll`, `scrollUp`, `scrollDown`, `debugtp`, `lockObject`,
   `backupsave`, `activateEquipment`, `fire`, `highlightNearby`, and raw keys `LeftMouseButton`,
   `AnyKey`, `Escape`. Observable success flags on the pawn: `input_use`, `input_E`, `input_fire`,
   `input_LMB`, `input_rotate`, `input_drop`, `input_crouch`, `input_scrollUp/Down`; held object
   `grabbing_actor`; look target `lookAtActor`. **Aim ray:** every look/use/pick-up/carry ray comes
   from `mainPlayer_C:arm` (camera manager location + forward); redirecting that one function to the
   right hand is the recommended hand-aim route (GAME-INTERNALS.md §3).

### Action inventory (current bindings)

| Context | Action (binding) |
|---|---|
| On foot | `Forward` W, `back` S, `Left` A, `Right` D, `Run` LShift, `Crouch` LCtrl, `Jump` Space, `Up` E / `Down` Q (ladder/fly, to confirm), `ragdoll` C, `noclip` V (debug) |
| Hands/objects | `use` E (pick up / grab / use; hold E = carry slabs, radial menu if enabled), `fire` LMB (throw while grabbing, use held item on keypads/keyholes, attack), `rotate` RMB (+mouse, while grabbing), `lockObject` MMB (fix in place), `Drop` R (press vs hold differ: place/hold vs to inventory, swapped by a setting; hold R + RMB + wheel = precise placement), `offhand` T, `activateEquipment` LAlt, `containerPut` LShift, `scrollUp/Down` wheel, `throwPath` unbound (shows throw arc) |
| Items/HUD | `hotbar_1..10` 1-0, `inventory` Tab, `flashlight` F, `highlightNearby` G, `Zoom` X |
| ATV | `atv_forward/back/left/right` WASD, `atv_brake` Space, `atv_turbo` LShift, `atv_lights` F, `atv_honk` LAlt, `atv_use` E, `atv_viewSteering` LCtrl, `atv_zoom` X, `atv_fall` C, `dismount` Esc |
| Computers (keyboard stays) | `coord_*` WASD/Enter/LShift/LAlt/1-3, `radar_*` WASD/Q/E/Enter/LShift, `Commit` Enter, `NewRow` unbound, `Undo` Z |
| System | `Pause` Esc, `quicksave` F5, `backupsave` F6, `LockMouse` F1, `spawnmenu` Q, `cheatmenu` Num0, `debugtp` Num., `superscreenshot`/`demosnow` unbound |

"To confirm" = semantics from play knowledge, to be checked in a capability run (see §4).

Semantics source (2026-11-27, links from the user): wiki.gg `Guides/Settings` (stub, edited
2026-11-25) and `Gamemodes/Tutorial` (marked WIP / possibly outdated, edited 2026-11-22). They
disagree on press vs hold R; T, G and containers aren't described. Timing-relevant settings: "E/R
Hold initial delay" 0.0 s and "E/R Hold delay" 0.2 s (so button passthrough must keep real press
length), "Release E instead of LMB for use interactions" (default on). Consequences for §2: grip = E
is the natural grab; trigger = LMB is throw/use; B must pass R's hold length through unchanged.
Default FOV 110 and "Panel FOV" 65 exist as settings (relevant to UEVR's FOV handling).

## 2. Proposed layout (Quest 3 Touch, right-handed)

Each button sends the **key currently bound** to the named action (read from Input.ini at start),
so every context (on foot, ATV) behaves as on the keyboard and a rebind in the game menu follows.

| Controller | Sends (action) | Notes |
|---|---|---|
| Right hand pose | aim | Game aim follows the right controller (UEVR `VR_AimMethod=2`); grabs and pick-ups go where the hand points |
| Right trigger | LMB (`fire`) | throw while grabbing, use held item on keypads/keyholes; held while held |
| Right grip | E (`use`; ATV `atv_use`) | grab / pick up / interact; hold = carry |
| A | Space (`Jump`; ATV brake) | |
| B | R (`Drop`) | press and hold keep their different meanings (place vs to inventory) |
| Right stick left/right | snap turn 45° (existing UEVR setting) | one turn per push |
| Right stick up/down | mouse wheel (`scrollUp/Down`) | whatever the wheel does in game |
| Right stick click | F (`flashlight`; ATV lights) | |
| Left stick | W/A/S/D (move; ATV drive) | digital (the game has no analog walk) |
| Left stick click | LShift (`Run`, also `containerPut`; ATV turbo) | held while clicked-and-moving (latched until the stick returns to centre) |
| Left trigger | LAlt (`activateEquipment`; ATV honk) | |
| X | LCtrl (`Crouch`; ATV steering view) | |
| Y | Tab (`inventory`) | |
| Menu button tap | Esc (`Pause`, `dismount`) | |
| Menu button hold 1 s | recentre view (mod) | Menu is ours from the dump: nothing else on it |
| **Left grip held = second layer** | | sends nothing on its own |
| Left grip + right stick | RMB + mouse movement (`rotate`) | rotate the held object; snap turn and scroll pause meanwhile |
| Left grip + A | MMB (`lockObject`) | |
| Left grip + B | T (`offhand`) | |
| Left grip + X | G (`highlightNearby`) | |
| Left grip + Y | X (`Zoom`; ATV zoom) | held while held |

Left on the keyboard for now: hotbar 1-0 (wheel cycles if the game does), quicksave F5, `ragdoll`
C, `Down`/`spawnmenu` Q, `noclip`, debug keys, and all computer screens.

Defaults (live settings): haptics off; left-handed swap available; stick-to-WASD threshold 0.5;
second-layer and recentre hold times live; both stick clicks together are avoided (UEVR's own
menu shortcut).

## 3. Integration route (proposed, unproven)

- **Read** controllers in UEVR Lua (`on_xinput_get_state`), then zero the state handed back to
  the game so the emulated pad can't move menu focus.
- **Send** keys into the engine, not the OS: call the player controller's `InputKey` (press/release)
  and `InputAxis` (MouseX/MouseY/MouseWheel deltas) with keyboard/mouse keys. No window focus
  needed, no stray keys to other apps. Fallback if the game ignores those: Win32 `SendInput` from a
  UEVR C++ plugin (needs the game window focused).
- Release everything on pause, focus loss, tracking loss, level load and the UEVR menu opening;
  a held button must be released and pressed again before it acts in a new context.
- **Aim:** `VR_AimMethod=2` (right controller). Known risks to test: (a) movement direction may
  follow the right hand instead of the head, because WASD moves along the control rotation;
  (b) the game's screen-centre crosshair and the item-selection marker won't sit where the hand
  points (ties into the open marker issue in STATUS.md) and will need a hit-point marker later.

## 4. First experiments after approval (one change per build)

1. Capability run: Lua logs the binding map, the player controller and pawn classes, and whether
   `InputKey(E)` from Lua makes the game do `use` (observed result, not just "sent").
2. Aim-only build: `VR_AimMethod=2`, nothing else; check pick-up follows the hand and which way
   WASD walks. Both runtimes.
3. Buttons build: the table above.

## 5. 6DoF hands: research and proposed ladder (2026-11-27)

User asked (2026-11-27 00:11) for research on keybinding and 6DoF controls. Sources: the game's
own grab code (`docs/GAME-INTERNALS.md` §3-4, pak read, not yet live), UEVR docs
([adding 6DoF](https://docs.uevr.io/usage/adding_6dof.html),
[UObjectHook Lua](https://docs.uevr.io/plugins/lua/types/UObjectHook.html),
[MotionControllerState](https://docs.uevr.io/plugins/lua/types/MotionControllerState.html)), and
other UEVR games (Subnautica 2's jbusfield 6DoF profile, [Road to VR 2026-06-19](https://roadtovr.com/subnautica-2-vr-mod-vr-controller-support/); method not confirmed). No existing
VOTV motion-controls profile was found.

**What the game gives us.** Grabbing is not an attach: E picks a target with the `arm()` ray, then a
`PhysicsHandleComponent` (`grabHandle`) pulls the object every tick to `arm(grabLen).end` with
rotation `grabTargetRotation` (`grabLen` 50-150 cm, wheel ±10). Heavy objects use constraints toward
the same point. Tools in hand are actors attached to the `weapon` mesh. So nearly all of "real hand
interaction" reduces to two inputs the game already reads: **where `arm()` says the ray/hand is**,
and **the carry rotation**. That is far cheaper than writing our own physics grab, and keeps the
game's own mass, collisions and drop/throw logic.

**UEVR tools.** UObjectHook can attach any component of the pawn to a controller (hand 0/1, offsets
saved with "Save State"; Lua: `UObjectHook.get_or_add_motion_controller_state(obj)` then
`set_hand`, `set_location_offset`, `set_rotation_offset`, `set_permanant`). "Permanent" stops UEVR
resetting the transform after rendering (needed when game logic reads it); risky on anything that
moves the player. Persistence across respawn/new objects isn't documented: test.

Proposed ladder, one rung per build, each with its own check; the user picks how far to go:

| Rung | What the player feels | How | Observable check |
|---|---|---|---|
| 1. Point with the hand | look-at, pick-up target and carried object follow where the right hand points (from the head) | `VR_AimMethod=2` only | `lookAtActor` changes when only the hand moves; held object follows the hand direction |
| 2. Ray from the hand | same, but the ray starts at the hand (no head parallax) | override `arm()` out params with the hand pose (UE4SS post-hook) and set `VR_AimMethod=0` | `arm.start` equals the hand position in a trace log |
| 3. Object in the hand | carried prop sits at the hand and turns with the wrist (no RMB needed) | in `arm()` for the carry call, `end` = hand + short offset; `grabTargetRotation` = hand rotation × the rotation at pick-up | prop centre within a few cm of the hand; wrist twist turns it; walls still block it (physics handle) |
| 4. Tools in the hand | flashlight, held tools and the arms mesh follow the hand | UObjectHook attach of `weapon` (and `light_R`), hide `arms`/`arms_off` | eye snapshot shows the item at the controller |
| 5. Physical throw | let go while swinging to throw | on release, set the dropped prop's velocity from the hand's last ~100 ms (Lua) | prop speed ≈ hand speed |
| 6. Near grab, off hand | grab what the hand touches; left hand holds the offhand item | sphere overlap at the hand instead of a ray; left-hand `arm()`/`weapon_off` | grab without pointing works; no grab through walls |

Not planned unless asked: arm IK/finger tracking (hide the arms instead), physical levers and
buttons (the game's buttons are E-use; pointing + grip already works), haptics (off by default).

Button mapping stays as §2 at every rung; only `rotate` (RMB) and the mouse wheel become optional
once rung 3 works. Rungs 2-6 need UE4SS next to UEVR in the same process (not yet run together) and
a live check that a UE4SS post-hook can rewrite `arm()`'s out params; fallback is a C++ UEVR plugin.

## Prompts

The game's prompts name keyboard keys ("E", "LMB"). With this layout the prompts stay true per
action but name the wrong device; a controller cheat sheet (or prompt edit through the game's
data) is a later item.
