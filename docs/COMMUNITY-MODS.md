# Community VOTV mods: what we can reuse

Survey of the 17 repos under [github.com/topics/votv](https://github.com/topics/votv), read
2026-11-27 (shallow clones of each default branch). Goal: find code, hooks and facts that help the
VR mod, and record what each license lets us do.

**Rules we follow.** Copy code only from licenses compatible with our MIT license (MIT, BSD,
CC-BY with care), keep the original copyright notice and credit the source in the file and in
`README.md`. Code with no license is all rights reserved: read it, learn the names and the ideas,
never copy it. Never copy game assets, or community conversions of them, from any repo.

**Version caveat.** Multivoid and libvotv target Alpha 0.9.0(n); dary1337's dumps are 0.10.09.
Our exe (2026-11-11) build string is not confirmed yet (RESEARCH.md §0). Class, function and field
*names* carried across these versions; raw *offsets* in any repo are version-bound, so resolve by
reflection (UE4SS / UEVR do this) and never hard-code an offset from these repos.

## Summary

| Repo | License | Use for us | Verdict |
|---|---|---|---|
| [VOTV-MP/Multivoid](https://github.com/VOTV-MP/Multivoid) | **MIT** (code + docs); `assets/paks/*.pak` are game-asset conversions, **not licensed** | Engine wrapper for the player, grab, interaction trace, menu, input mode; build detection; save (GVAS) reading | **Main source.** Facts and code reusable with attribution; skip `assets/` |
| [modestimpala/libvotv](https://github.com/modestimpala/libvotv) | none | `mainPlayer_C` / `mainGamemode_C` field list for UE4SS C++ | Reference only |
| [modestimpala/UE4SS-Build-Guide](https://github.com/modestimpala/UE4SS-Build-Guide) (moved to [VotV-RE-UE4SS](https://github.com/modestimpala/VotV-RE-UE4SS)) | none | How to build UE4SS 3.0 C++ mods for VotV (MSVC 14.40, header-dump converter) | Reference only, if we ever need a C++ UE4SS mod |
| [NotGod3744/ConsoleUtility_VOTV](https://github.com/NotGod3744/ConsoleUtility_VOTV) | **MIT** | UE4SS Lua: read/set the console state, run console commands from script | Reusable with attribution (small) |
| [dary1337/VotV_props](https://github.com/dary1337/VotV_props) | none | 0.10.09 lists: callable functions, actors, maps, props; a UE4SS Lua "call function on mainPlayer_C" console | Reference only (has spoilers) |
| [modestimpala/VotVChaosMod](https://github.com/modestimpala/VotVChaosMod) | CC-BY-4.0 | Twitch effects mod; shows VoidMod/pak-mod layout | Not useful for VR |
| [yupl0ve/VoidEngine-VotV](https://github.com/yupl0ve/VoidEngine-VotV) | none, **commercial closed source** (README only) | Claims CPU tick throttling of off-screen props + TAAU presets | Idea only; see graphics notes |
| [TheAlarm117571/VotV-RenderingIconPlus](https://github.com/TheAlarm117571/VotV-RenderingIconPlus) | none | Icon cache Lua mod | Not useful |
| [JackStar6677-1/VotV-Points-Editor](https://github.com/JackStar6677-1/VotV-Points-Editor) | MIT | Byte-patches points in a save, with backups | Not useful (Multivoid's GVAS reader is better) |
| [modestimpala/VotV_ghostmap](https://github.com/modestimpala/VotV_ghostmap) | none | Auto-generated editor recreation of every game asset (a09n) | **Do not use or redistribute** (derived from game assets) |
| [TheAlarm117571/-VotV-Carry-the-planet](https://github.com/TheAlarm117571/-VotV-Carry-the-planet) | none | VoidMod pak (infinite inventory) | Not useful |
| [KemiKep/Syka-VOTV](https://github.com/KemiKep/Syka-VOTV) | none | Cheat, README only | Not useful |
| VOTV-MP/Multivoid-wiki, Multivoid-server | none | Empty / planned | Nothing yet |
| j1sk1ss/AnizottiVOTV.EXMPL, wolfey-dev/votv-quickshell, Obimydudee/SpaceTranslator | various | Minecraft mod, desktop shell, Discord bot | Off-topic |

No existing VR attempt is on the topic page.

## Multivoid: the parts that matter for VR

A UE4SS-loaded DLL (imports nothing from UE4SS) with its own reflection, MinHook `ProcessEvent`
detour and Blueprint script-VM gate. Split: `src/votv-coop/src/ue_wrap/` wraps the engine with no
gameplay (the useful part for us), `coop/` is networking. `docs/code-map.md` maps every concept.
Each fact below was read from its headers; it agrees with our `docs/GAME-INTERNALS.md` and adds to it.

### Player, aim, interaction (`ue_wrap/engine/engine_mainplayer.h`)

- **Hold point:** each tick the player calls
  `grabHandle->SetTargetLocationAndRotation(camera location + camera forward * grabLen, grabrot)`.
  A puppet with its tick off is driven by calling `SetTargetLocationAndRotation` itself, which is
  the same move we need to pull a held prop toward a hand.
- **Reach:** `mainPlayer_C.armLength` is 200, or the held item's own value from its `list_weapons`
  row (mop, lamp, breather reach further).
- **Two answers for "what am I aiming at":** `hitResult` (actor, component) is the raw trace that
  the game's own tool code reads; `lookAtActor` is derived from it later in the tick and is skipped
  while a grab is open. A hand ray must feed `hitResult`'s source (the `arm` function), not only
  `lookAtActor`.
- **Use without the E key:** `useSelectedAction()` does what E does once its gating passes (nothing
  grabbed, a look-at actor that answers). `setActionIndex(int)` picks the radial menu entry.
  `MainPlayerHasSelectedAction` notes the game settles the look one tick after the trace lands, so a
  press on the same tick is denied.
- **Pick up into the hand:** `Hold Object(target, manual=true)` then `addEquip` / `updateHold`
  spawns the hand item as `holding_actor`. `putObjectInventory2(target, noNotify)` stores it.
- **Grab state fields:** `grabbing_actor` (physics-handle carry), `holding_actor` (hand item or
  pile carry), `grabsHeavy`, `Heavy`, `grabLen`; `ReleaseMainPlayerGrabIfHolding` lets go.
- **Input flags as fields:** `input_run`, `input_rotate`, `input_drop`, `input_fire`, `input_alt`,
  `input_forward/back/left/right`, `deactivateMouseInput` (libvotv's list). These are what the
  Blueprint reads, so they are a fallback for remapping when a key event is awkward.
- **0.10.x has a second hand** (dary1337's 0.10.09 dump): `better_holdItem_mainHand`,
  `better_holdItem_offHand`, `bindHoldingActorDestroy_off`, plus `dropGrabObject`, `smoothGrab`,
  `setHeavyGrabArm`, `skipGrabRadial`. Check whether our build has them before designing two-hand holds.

### Main menu and UI

- The main menu widget is **`ui_menu_C`**, and the same class is the pause menu (`isPause` bool).
  The game mode holds it in `mainGamemode_C.pause_mainMenu`; in the menu level that field is the
  main menu. Members: `button_start` (NEW GAME), `txt_version`, `switcher_widgets` (the sub-screen
  layer holding `ui_settings_C`, `ui_saveSlots_C`). Multivoid hooks `ui_menu_C::Tick` (it runs while
  the menu is visible), so that is a reliable "menu is up" signal.
- Input focus is set through `WidgetBlueprintLibrary.SetInputMode_UIOnlyEx`, `SetInputMode_GameAndUIEx`,
  `SetInputMode_GameOnly` and the controller's `bShowMouseCursor` (`coop/input/input_owner.cpp`):
  the hook points for keeping the cursor visible in VR menus.
- HUD and screen covers: `ui_UI_C` (HUD), `blackScreen_C`, `ui_bloodLossBlur_C`,
  `ui_damageIndicator_C`; in-world screens `ui_laptop_C`, `ui_console_C`, `ui_notebook_C`,
  `ui_playerInventory_C`, `ui_spawnmenu_C` (`ue_wrap/engine/screen_state.h`, `devices/laptop_widget.h`).
- `docs/votv-ui-style.md` records the game's UI style if we ever add native-looking buttons.

### Engine and tooling

- **Render APIs:** the game launches on DX11, DX12 or Vulkan (`docs/feasibility.md`). UEVR covers
  DX11/DX12 only, so our launcher should force one of those.
- **Build detection** (`ue_wrap/core/game_build.h`, `facts/game_builds.inc`): identifies the build
  by the exe's link timestamp plus the pak index hash. Good model for the `vr-mod-game-patches`
  build pin.
- **Save files** (`engine/gvas_meta`, `save_browser`): GVAS metadata reader that scans saves on a
  worker thread. Reusable if we read `settings.sav` from our own tooling.
- **Window input** (`coop/input/game_window_proc.h`): one subclass of the game window that follows
  it when the engine recreates the window.
- **Conflict risk with UEVR:** Multivoid detours the swap-chain present (DX11/DX12/Vulkan) and
  `ProcessEvent`, as UEVR does. Running both is untested; if players ask for VR co-op, test that
  pairing before claiming it.

## Graphics and performance notes

- VoidEngine (closed, paid) claims its FPS gains from throttling `ReceiveTick` on props that are far
  or outside the camera's view. Do not use it, and treat any similar "out-of-FOV" culling mod as
  suspect in VR: the game's flat camera FOV is not the headset's, so props at the edge of the view
  could freeze. Its TAAU presets are ordinary `r.` console variables we can set ourselves.
- ConsoleUtility (MIT) shows how to run console commands from UE4SS Lua, if UEVR's own Lua
  `execute_command` is not enough.

## How to credit

If we copy code from Multivoid or ConsoleUtility, keep their header comment, add the source URL
and commit, and list it under a "Third-party code" section in `README.md` with the MIT notice.
Copying names (class, function, field identifiers) needs no credit, but we cite the repo anyway.
