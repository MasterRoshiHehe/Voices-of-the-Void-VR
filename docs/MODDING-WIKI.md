# VOTV modding wiki and Linux gist: notes for the VR mod

Read 2026-11-27. These notes are in our own words; the sources are not copied.

- **VotV Modding Wiki** by Questwalker and contributors: [site](https://questwalker.github.io/votv-modding-wiki/),
  [source](https://github.com/Questwalker/votv-modding-wiki) (commit `f7a4c65`, 2026-11-20). **GPL-3.0**, so we
  link and summarise but don't paste its text or images into this MIT repo. All 40 pages in its
  `docs/` folder were read. The site has no other pages: no blog, and only a landing page outside `docs/`.
- **Linux VotV + r2modman guide** by Diyagi: [gist](https://gist.github.com/Diyagi/2fa085858e6c2f3f9f75b37b46d5c036).
  No license is stated, so it is reference only.

See also [COMMUNITY-MODS.md](COMMUNITY-MODS.md) (repos under the votv topic) and
[GAME-INTERNALS.md](GAME-INTERNALS.md).

## What matters for us

### Loading and compatibility

- **The community loader is Thunderstore's "unreal shimloader".** It is a fork of RE-UE4SS that
  loads as a `dwmapi.dll` proxy in `VotV\Binaries\Win64` next to `UE4SS.dll`, and it takes
  `--mod-dir`, `--pak-dir` and `--cfg-dir` launch arguments so that r2modman profiles work. Most players
  with mods have this. Any UE4SS helper we ship has to coexist with it, and with UEVR injecting into the
  same process. That combination is untested.
- **Some early 0.9.0 builds shipped an anti-tamper check** that crashes the game when it finds the
  mod loader. The leftover `dwmapi.dll` and `UE4SS.dll` also "brick" those installs until the two files
  are deleted. Our launcher's build pin should refuse UE4SS helpers on such a build, and our
  cleanup must remove every file we add (AGENTS.md already says "always clean up").
- **Plain RE-UE4SS v3.0.1 stable cannot load Blueprint paks from sub-folders of `LogicMods`.**
  The experimental builds and the shimloader fixed this.
- The common shimloader crash causes are antivirus quarantine of `dwmapi.dll`, non-Latin characters
  in paths, and OneDrive, external drives or system folders. These belong in our player troubleshooting notes.
- Useful paths: saves are in `%localappdata%\VotV\Saved\SaveGames`, and the item icon cache is in
  `%localappdata%\VotV\Assets\icons\items` (it is rebuilt when the `list_props` row count changes).
  `UE4SS.log` sits next to the exe.

### Three ways to mod, and which fit VR

- **Lua (UE4SS):** no build step, and scripts hot-reload from the UE4SS console. Lua can hook and
  observe functions but often cannot cancel or rewrite them. Out-parameter rewriting, which is what
  we need for the `arm` aim ray, has to be tested before we rely on it.
- **C++ (UE4SS):** can intercept calls and change their parameters. A C++ mod is tied to the UE4SS
  version it was built against. It needs MSVC and Epic GitHub access for the UEPseudo headers.
- **Blueprint pak:** a UE **4.27.2** project with a `Mods/<Name>/ModActor` actor that
  BPModLoaderMod spawns on load (it also calls `PreBeginPlay` and `PostBeginPlay` if they exist).
  Only our own assets get packed, by chunk ID: enable "Allow ChunkID Assignments" and "Generate Chunks",
  turn off "Share Material Shader Code", and cook `/Game`. Then rename `pakchunkN-WindowsNoEditor.pak` to
  `<Name>.pak`. The pak can only use plugins the game ships with. Sounds need the
  `WindowsTargetSettings` sample-rate overrides in `DefaultEngine.ini`.
  For us this is the route if we need **in-world VR widgets or actors** that UEVR Lua can't make,
  such as a 3D menu panel, a hand reticle mesh or a world-space selection marker.
- **Ghostmappings** are empty look-alike assets at the game's paths that let a Blueprint mod
  reference `mainPlayer_C`, `prop_C` and other game classes in the editor. They must never be packed into the mod.
  The wiki recommends modestimpala's VotV_ghostmap (no license) or NynrahGhost's. If we use one, we
  use it locally only and never commit it (COMMUNITY-MODS.md).

### Interaction and input facts (for controls)

- **The prop interaction interfaces** are `int_player`, `int_objects` and `int_save`, on `prop_C`:
  - `lookAt` returns whether the interaction menu shows, the hint text, and an optional
    "bound object replace" component for the selection box size.
  - `getActionOptions` fills the hold-to-use action menu, as strings or as
    `interactionEnum` values (14 actions such as Grab, Toggle, Activate), with optional overlay labels.
  - The chosen action arrives as the `actionName` event for string lists, or `actionOptionIndex`
    for enum lists. Multivoid hooks `actionOptionIndex` heavily, and it confirms this is the dispatch point.
- **Prop flags in `list_props` (`struct_prop`):** `canHold` means it can be picked up and put in
  containers. `heavy` means a world-dynamic collision body, no container, no CCD (so it can tunnel
  through walls when it moves fast), and the heavy-grab path. `canCollect` lets it go into the
  inventory, and `ignoreInteractions` blocks the player. Hand grabbing must respect these and should
  limit how fast heavy objects can be moved, because they have no CCD.
- **Fusion** (NynrahGhost, on Thunderstore) merges `_<table>` datatables into the game's tables and
  is described as also touching **input events**. A row added to the keybinds table does *not* create a
  working bind, so we can't add VR actions that way. We would still need a hook.
- **VoidMod** (framework for 0.8.2c and older) is abandoned and closed source. Skip it.

### Publishing (for later)

- Thunderstore zips need `manifest.json`, `README.md` and `icon.png`. Lua or DLL mods also need
  `mod/enabled.txt`, and the folders are `mod/`, `pak/` and `cfg/`. This matters if we ever ship the
  UE4SS side through r2modman. The UEVR side still needs its own injector or launcher.
- **Community norm:** the official community bans datamining that spoils the game's secrets.
  Our public repo should keep to identifiers and mechanics (as GAME-INTERNALS.md does) and never
  describe story content or hidden events.

### Linux gist

- Under Proton/Wine the shimloader needs `WINEDLLOVERRIDES="dwmapi,version=n,b"` (not `winhttp`).
  The mod paths need a `Z:` drive prefix, and on case-sensitive file systems `UE4SS.dll` has to be
  renamed `ue4ss.dll`. The gist also sets `WINE_DO_NOT_CREATE_DXGI_DEVICE_MANAGER=1`, which it says
  fixes the in-game TV (video playback). Linux VR isn't in scope; note it if a player asks.
