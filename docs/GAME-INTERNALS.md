# Voices of the Void: game internals for VR hand aiming and grabbing

Reference for the motion-controller work (stage B). Game build: exe SHA-256 `5e690d8f…f6cc`
(RESEARCH.md §0), UE 4.27.2. First written 2026-11-27 by the game-internals thread.

**How this was found.** Read-only analysis of the cooked assets in
`VotV\Content\Paks\VotV-WindowsNoEditor.pak` (pak v11, not encrypted, not compressed; 47,606 files,
21,603 `.uasset`). Small local Python readers list the pak, pull single assets, and read each
asset's name, import and export tables; a heuristic scan of each Blueprint function's bytecode
lists the functions it calls and the variables it touches in order. Nothing from the game is in
this repo: the readers, extracted assets and reports live in `F:\Moddings\VOTV\dumps\` (outside
the repo). The names below are identifiers (class, function, variable names), the minimum needed
to hook them. A live UE4SS v4.0.0 dump (flat run, main menu, 2026-11-27 01:31) confirmed the signatures and defaults marked **live**; see "Files checked".

Evidence level used below: **pak** = read from the cooked asset (names and call order, strong);
**inferred** = deduced from call order, needs a live check; **live** = confirmed in a running game.

## 1. Classes at a glance

| Role | Class (path) | Parent | Notes |
|---|---|---|---|
| Player pawn | `mainPlayer_C` (`/Game/main/mainPlayer`) | `Character` | All player logic is in this one BP (654 exports, ubergraph ~270 KB) |
| Player controller | `MyPlayerController_C` (`/Game/MyPlayerController`) | `PlayerController` | Empty BP, no functions: input and aim live in the pawn |
| Camera manager | engine default `PlayerCameraManager` (**live**: the instance in `/Game/maps/preLoad` is `/Script/Engine.PlayerCameraManager`) | | The aim ray reads this actor's transform (§3) |
| Game mode | `mainGamemode_C` (`/Game/main/mainGamemode`) | `GameModeBase` | Holds `playerInterface` (the HUD widget), hotbar UI refs, settings |
| HUD widget | `ui_UI_C` (`/Game/umg/interfaces/ui_UI`) | UserWidget | Crosshair, hover text, selection marker, hotbar, action list |
| Inventory | `inventoryComponent_player_C` (`/Game/umg/test/`) | `inventoryComponent_C` → ActorComponent | Component on the pawn (`inventoryComponent_player`) |
| World props | `prop_C` (`/Game/objects/prop`) | Actor | Base of pick-up-able objects; implements `int_player`, `int_objects` |
| Interfaces | `int_player_C`, `int_objects_C`, `int_playerInput_C`, `int_inventory_C`, `int_coms_C` | Interface | §5 |
| Native module | `/Script/VotV` | | `bpCodeLib` (`BoundingBox2D`, `BoundingBox2DPoints`, `isPointInWater`, …), `thingsAndStuffLib` (save byte helpers), `CompressedSaveLoadLib`, `mn_player1__CPP` |

## 2. Player pawn `mainPlayer_C`: components

| Component (variable) | Type | Purpose |
|---|---|---|
| `CollisionCylinder` | CapsuleComponent | Character capsule (engine default) |
| `CharMoveComp` | CharacterMovementComponent | Walking, crouch, swim, jump |
| `cameraRoot` | ArrowComponent | Camera pivot; `alightViewToFloor` sets its relative rotation (tilts the view to the floor slope); mirror mode flips it |
| `Camera` | CameraComponent | The game camera (`bUsePawnControlRotation` is set from the ubergraph) |
| `crouchRoot`, `lag`, `cameraLag`, `lag1`, `lag_fl`, `lag_fl1`, `arms_lag` | Billboard / SpringArm | Camera and view-model lag rigs (head-bob/sway candidates) |
| `arms`, `arms_off` | SkeletalMeshComponent | First-person arms, main and off hand |
| `weapon`, `weapon_off`, `wSubmesh` | StaticMeshComponent | Hand-held item slots; `better_holdItem_mainHand` attaches the spawned held actor to `weapon` |
| `viewmodel`, `viewmodel_anim_L/R`, `viewmodel_anim_pull_L/R` | Billboard / Scene | View-model anchors |
| `grabHandle` | **PhysicsHandleComponent** | Carries physics props (§4) |
| `grabComp`, `grabrot`, `heavyRot` | StaticMesh / Arrow | Grab helpers; `grabrot` holds the carried object's target rotation |
| `heavyGrab`, `heavyPull`, `heavyPull_loc`, `pullComp`, `pullSubcomp` | PhysicsConstraint / StaticMesh | Heavy-object drag (constraints instead of the handle) |
| `precMesh`, `precMesh_overlap` | StaticMeshComponent | Precision-placement ghost (`meshPlace`) |
| `lookatBox` | BoxComponent | Moved each tick to the look-at hit point (`LookAtFunction`) |
| `WidgetInteraction` | WidgetInteractionComponent | 3D widget clicks (`widgetInteract_mousePress`, `interactedWithWidget`) |
| `inventoryComponent_player` | inventoryComponent_player_C | Inventory |
| `weaponComp_gravityGun` | comp_gravitygun_C | Gravity gun (own trace, §3) |
| `light_R` | SpotLightComponent | Flashlight |
| `playermodel`, `mesh_playerVisible`, `CharacterMesh0` | SkeletalMesh | Body (ragdoll, shadows) |
| also | | `PostProcess_pl`, `mic` (AudioCapture), `emf_sphere`, `comp_emf`, `comp_metalDetector`, `comp_jetpack`, `radarPoint`, `physicsImpact`, many AudioComponents |

## 3. Aim ray: where it starts, and the redirect point

**One function builds the aim ray for almost everything: `mainPlayer_C:arm`** (pak).

`arm(float customLength, FVector& Start, FVector& End, FRotator& Rotation)` (**live** signature, CXX header):

- `PCM = GetPlayerCameraManager(0)`
- `start = PCM:K2_GetActorLocation()`
- `rotation = PCM.TransformComponent:K2_GetComponentRotation()`
- `end = start + PCM:GetActorForwardVector() * (customLength > 0 ? customLength : armLength)`

So the ray starts at the **camera manager's location** and points along **its forward vector**, not
the `Camera` component and not the controller directly. The PCM copies the camera's POV each frame,
and the camera uses pawn control rotation, so in flat play this is "from the eye, where the mouse
looks". Under UEVR the head pose is applied to the rendered view, not to the PCM actor, which is why
the hover marker and picks follow the mouse and not the head (open issue in STATUS.md).

Callers of `arm` (pak):

| Caller | Use | Trace |
|---|---|---|
| `LookAtFunction` (each tick from the ubergraph) | what you look at: hover text, selection marker, `lookAt` interface, grab target | `SphereTraceSingle(arm.start, arm.end, radius 2)`, then `SphereTraceSingleForObjects` radius 10 (physics objects), then `LineTraceSingleForObjects` (static/dynamic); results in `hitResult`, `lookatActorCurrent`, `lookatComponentCurrent`, `lookAtActor`, `lookAtComponent` |
| ubergraph tick | **held object position**: `arm(grabLen)` then `grabHandle:SetTargetLocationAndRotation(arm.end, grabTargetRotation)` | |
| `useArm` | short-range use | `SphereTraceSingle` from `arm(…)` |
| `attack` | melee / tool hit | `LineTraceSingle` from `arm(…)`, `playerHitWith`, `damageByPlayer` |
| `meshPlace` | precision placement (3 calls) | `LineTraceSingleForObjects` |
| `teleportWObackrooms` | special | |

Not through `arm` (need their own redirect if they matter):

- `comp_gravitygun_C:trace`: own `GetPlayerCameraManager` location + forward → `SphereTraceSingleForObjects`.
- `traceThrow` / `throwHoldingProp`: throw arc from `Camera` forward (`cameraLocation`) and from `weapon`
  (`hit_fromCamera`, `hit_fromWeapon`, `Blueprint_PredictProjectilePath_ByTraceChannel`).
- `kick`: from the actor location. `Place Drop Object from Hotbar Slot`: uses the PCM (4×).
- `makeLookAt`: forced look-at (cutscenes, sitting) writes `SetControlRotation`.

**Recommended redirect (best single point):** a post-hook on `mainPlayer_C:arm` that replaces
`start`, `end` and `rotation` with the right controller: `start = hand location`,
`rotation = hand rotation`, `end = start + forward(hand) * L`, with `L` = the length the game asked
for (`customLength` if > 0, else `armLength`; or keep `|end - start|` from the original result).
This moves look-at, hover text, use, pick-up target, melee and the carried object to the hand in one
place and leaves the camera, movement and HUD alone. Keep `VR_AimMethod=0` (game) with this route,
so UEVR doesn't also rotate the control rotation.

How, by tool (to verify on the first build):

- **UE4SS Lua:** `RegisterHook("/Game/main/mainPlayer.mainPlayer_C:arm", pre, post)`; in the post
  callback write the out params (`start`, `end`, `rotation`). Needs a live check that writes to
  BP out params in a post-hook reach the caller in UE4SS v4.0.0.
- **UEVR Lua (1.05):** UEVR's `UFunction:hook_ptr` hooks a function's native pointer; BP functions
  all share the script VM thunk, so hooking a BP function this way is not a clean per-function hook.
  Safer UEVR-only options: (a) each tick, move the **PCM actor** to the hand before the pawn ticks
  (fragile: the PCM rewrites its transform in its own update), or (b) set `VR_AimMethod=2` (right
  controller) so the control rotation, and hence the PCM rotation, follows the hand; the ray then
  starts at the head but points where the hand points (cheapest first experiment, CONTROLS.md §4.2).
- Hand pose source in UEVR Lua: `uevr.params.vr.get_pose(index)` with the right controller index
  (`get_right_controller_index()`); UEVR's UObjectHook motion-controller attachments are an
  alternative for attaching the held `weapon` mesh to the hand.

Distances (pak, ubergraph constants): `grabLen` set on pick-up to `clamp(dist(Camera, object), 0, 150)`;
mouse wheel while holding changes it by ±10, clamped 50..150 (cm). **Live** class defaults: `armLength = 200.0`, `grabLen = 100.0` (cm). Live offsets (CXX dump, this build): `Camera` 0x570, `grabHandle` 0x6C0, `HitResult` 0x79C, `armLength` 0x874, `grabLen` 0xA40, `lookAtActor` 0xB10; use names, not offsets, from Lua.

## 4. Holding, grabbing, throwing

| Step | Functions / variables (pak) |
|---|---|
| Pick-up decision | `useAction(hitResult)` on `use` (E): checks `int_player` on the hit actor, `asProp`, `IsSimulatingPhysics`; calls `pickupObject`, `player_use`, `kicked`, `lookAt` |
| Physics carry | `pickupObject` → ubergraph: `grabrot` set from the object, `grabHandle:GrabComponentAtLocationWithRotation(grabbing_component, None, centre of mass, rot)`, `SetInterpolationSpeed(grab_speed)` with `grab_speed = clamp(1000 / mass, 5, 100)`; `grabbing_actor`, `grabbing_component`, `grabLen`, `grabTargetRotation`; events `playerGrabbed_pre`, `playerGrabbed` on the object |
| Each tick while carrying | `grabHandle:SetTargetLocationAndRotation(arm(grabLen).end, grabTargetRotation)` |
| Rotate held object | `rotate` (RMB) sets `input_rotate`; mouse X/Y then rotate `grabrot` instead of the view (`mouseAxis_X/Y`, `mouseSens`) |
| Heavy objects | `switchToHeavyDrag` → `heavyGrab` / `heavyPull` constraints, `grabsHeavy`, `grabHeavy_pull`, events `heavyObjectGrabbed/Pulled/Dropped` |
| Drop | `dropGrabObject` → `grabHandle:ReleaseComponent`, break heavy constraints, `justDropped`, `objectDropped` event |
| Throw | `throwHoldingProp`, `traceThrow`, `throwShit`, `drawThrowPath` (`throwPath` action), `thrown` on the object |
| Hand-held items (tools) | `better_holdItem_mainHand` / `better_holdItem_offHand`: spawn the item actor, `K2_AttachToComponent(weapon)`; `holdingActor_main`, `holdingObjectName_main`; `playerHandUse_LMB/RMB`, `playerHandRelease_LMB/RMB`, `playerHandMouse`, `playerHandMouseWheel` are sent to the held item |
| Precision placement | `isPrecisionPlacement`, `meshPlace`, `updatePrecPlace`, `precAngle` (wheel ±5°), `precisionPlacemet_drop` |

## 5. Interaction / use

- Trace: `LookAtFunction` (§3), origin `arm`. Hit info lives in pawn variables `hitResult`,
  `lookatActorCurrent`, `lookatComponentCurrent`, `lookAtActor`, `lookAtComponent`, `isLookingAt`.
- Interfaces called on the target: `int_player` (`lookAt(hit) -> return, text, boundObjectReplace, number`,
  `player_use`, `playerTryToGrab`, `playerTryToHold`, `playerTryToCollect`, `canBeCollectedOrPickedUp`,
  `asProp`, `playerGrabbed`, `beginHoldingObject`, …) and `int_objects` (`playerUsedOn`, `getActionOptions`,
  `actionOptionIndex`, `actionName`, `playerLookAway`, `lookedAt`, `playerHandUse_LMB/RMB`, …).
- Action list (hold E radial): `buildActionList`, `getActionOptions`, `selectedAction`, `useSelectedAction`,
  `setActionIndex`, `fixActionIndex`; HUD `ui_UI.buildActions`, `canvas_actionList`, `selectingAction`.
- Input flags set by the input events, read by the tick: `input_use`, `input_E`, `input_fire`,
  `input_LMB`, `input_rotate`, `input_drop`, `input_crouch`, `input_scrollUp/Down`, `releaseEToUse`.

## 6. Inventory and hotbar

- Component: `inventoryComponent_player` (`inventoryComponent_C`: `addItemAsObject`, `addItemAsData`,
  `addItemAdvanced`, `removeInventoryItem`, `calculateVolumes`, `isVolumeOverflow`, `dropOverflowing`,
  `canPutItemInSlot`, `doubleClickAction`; player subclass adds `equipmentSpec`).
- Pawn: `addObjectToInventory`, `InsertHandItemIntoHotbar_main/_offHand`, `insertObjectIntoHotbarSlot`,
  `Place Drop Object from Hotbar Slot`, `destroyAndPutBackMainHandItem`, `dropItem_mainhand/_offhand`,
  `hotkeyAction`, input events `hotbar_1..9`, `inventory` (Tab), `offhand` (T).
- Hotbar state: `gamemode.ui_FLI_inventory.hotbarSlots`, `hotbarSelectedSlot`; HUD `ui_UI.hotbarVisSlot_0..7`,
  `hotbarVisSlot_offhand`, `canvas_hotbar`, `cusSelectHotbarSlot`, `updateSlotInv`.
- Inventory screen: `ui_playerInventory`, `ui_FreeLayoutInventory`, `umg_inventory` inside `ui_UI`.

## 7. Crosshair and selection marker (`ui_UI_C`)

- Crosshair: `switcher_crosshair` (WidgetSwitcher, screen centre) with `canvas_cursor_cross/tri/no/class`;
  type and opacity from settings `crosshairType`, `crosshairOpacity` (enum `enum_crosshairType`).
- Hover text and marker: pawn `LookAtFunction` → `gamemode.playerInterface.openHovertext(lookAtBoundsReplace,
  text, name, lookAtCenter)` and `setLeftSideText`. Widget side: `calcSize` uses native
  `bpCodeLib.BoundingBox2DPoints` / `BoundingBox2D` with the player controller to project the object's
  bounds to screen; `projectClamped` uses `ProjectWorldLocationToWidgetPosition`; drawn into
  `canvas_lookatBounds`, `canvas_lookatP`, `img_hovertext`, `text_hoverItemName`, `text_hoverItemHelp`.
- So the marker is a **flat-screen projection through the game camera**. With the hand ray it will
  still be drawn as if seen from the game camera on UEVR's UI panel. VR fix options: hide
  `canvas_lookatBounds`/`switcher_crosshair` and draw a world-space hit marker at `hitResult` (from
  Lua), or keep the text but anchor it to the hit point.
- Highlight: `makeHighlighted`, `highlight_effects`, `highlight_actors`, `overlapBegin/End_highlight`,
  `highlightNearby` (G).

## 8. Input, look and camera

- Input bindings are action mappings only (CONTROLS.md §1). In the pawn they arrive as
  `InpActEvt_<action>_K2Node_InputActionEvent_N` events (pressed/released pairs) for: `drop`, `offhand`,
  `spawnmenu`, `alt`, `throwPath`, `run`, `dismount`, `cheatmenu`, `rotate`, `crouch`, `jump`, `inventory`,
  `noclip`, `forward`, `back`, `left`, `right`, `use` (3 nodes), `zoom`, `hotbar_1..9`, `superscreenshot`,
  `flashlight`, `quicksave`, `undo`, `ragdoll`, `scrollUp`, `scrollDown`, `debugtp`, `lockObject`,
  `backupsave`, `activateEquipment`, `fire`, `highlightNearby`; raw keys `LeftMouseButton`, `AnyKey`,
  `Escape`.
- **Mouse look:** axis events `InpAxisEvt_mouseX` / `InpAxisEvt_mouseY` (axis names `mouseX`, `mouseY`
  bound in code, not in the ini) and `InpAxisKeyEvt_MouseWheelAxis`. The ubergraph applies
  `AddControllerYawInput` / `AddControllerPitchInput` with `mouseAxis_X/Y`, `mouseSens`, `isMirror`,
  a log curve and a heavy-grab slow-down; blocked by `deactivateMouseInput`, `blockMouseInput`,
  `addMouseInputBlocker`, and redirected to object rotation while `input_rotate`.
- **Movement:** `forward/back/left/right` actions set flags; the tick calls `AddMovementInput` (6 sites),
  direction presumably from actor/control rotation (inferred; check before right-hand aim).
- Camera: `Camera` (pawn control rotation), view tilt `alightViewToFloor` (`canAlignToFloor`), lag rigs
  (§2), FOV from settings `defaultFOV` and the `zoom` timeline (`Zoom` action), sitting/forced look
  `makeLookAt`, ragdoll camera in `ragdollMode`. Candidates to neutralise in VR: `cameraRoot` tilt,
  camera lag spring arms, zoom FOV.

## 9. Hook recommendations (summary)

1. **Aim/grab/use from the hand:** post-hook `mainPlayer_C:arm` (UE4SS) and overwrite its out params
   with the right-hand pose. Cheapest first test without hooks: `VR_AimMethod=2`.
2. **Gravity gun:** `comp_gravitygun_C:trace` uses the PCM directly; redirect separately if needed.
3. **Throw:** `traceThrow` uses `Camera`; later.
4. **Marker:** hide `ui_UI` `canvas_lookatBounds` and `switcher_crosshair`; draw a 3D marker at the
   pawn's `hitResult` impact point.
5. **Buttons:** keep sending the bound keys (CONTROLS.md §3); state variables above (`input_*`) show
   whether the game took them.

## 10. Open unknowns

- Live confirmation of the call-order ("pak") claims with a spawned player: the menu dump had no `mainPlayer_C` instance (no save was loaded; it needs someone to click into a save). Still unknown: trace channels, `arm` call rate, live `arm` results under UEVR.
- Whether UE4SS v4.0.0 post-hooks can change BP out params of `arm` (and the cost per call: `arm` runs
  several times per tick).
- Component attach hierarchy (which spring arm/camera the `weapon`/`arms` hang from).
- UE4SS and UEVR side by side in one process (both hook the engine; not yet run together).

## Files checked (all under `F:\Moddings\VOTV\dumps\`, outside the repo)

- `pak_filelist.txt` (pak listing), `pak_extract\VotV\Content\...` (extracted assets: `main\mainPlayer`,
  `main\mainGamemode`, `MyPlayerController`, `main\interfaces\*`, `main\enums\*`, `umg\**`,
  `objects\prop`, `objects\components\*`).
- `reports_mainPlayer.txt`, `reports_ui_UI.txt`, `callscan_player_all.txt`, `callscan_player_sel.txt`.
- Readers: `_scripts\pakread.py`, `uasset_names.py`, `callscan.py`, `window.py`, `entry.py`.
- Live dump `ue4ss_2026-11-27_0131\`: `UE4SS_ObjectDump.txt` (68 MB), `CXXHeaderDump\` (2,571 files; `mainPlayer.hpp`, `ui_UI.hpp`, `VotV.hpp`, …), `UHTHeaderDump\`, `UE4SS.log` (probe lines start `[votvdump]`). Made by `ue4ss_stage\ue4ss\Mods\VotvInternalsDump\Scripts\main.lua` (loads the key BP classes 20 s after start, logs CDO values, runs the three dumpers; also hooks `arm` and logs component parents if a player spawns).

## Reproducing the live dump

UE4SS v4.0.0 (`UE4SS_v4.0.0.zip`, SHA-256 `251ad0d1…0c81e45`, matches the release digest) is staged in
`F:\Moddings\VOTV\dumps\ue4ss_stage\`. Copy `dwmapi.dll` and the `ue4ss\` folder next to
`VotV\Binaries\Win64\VotV-Win64-Shipping.exe`, run `scripts\run-vr.ps1 -NoInject` (flat, no UEVR),
wait for `MENU DUMP DONE` in `ue4ss\UE4SS.log`, close the game, move the outputs out, delete
`dwmapi.dll` and `ue4ss\`. Not yet run together with UEVR.
