# Building a VR mod for a flat game: handoff from the Sims 4 VR project

Written 2026-11-26. Audience: an AI (or person) starting a VR mod for a different PC game. Everything here comes from about six weeks of building a full 6DoF OpenXR mod for The Sims 4 (DX11, Quest 3 over Virtual Desktop). Sims-specific detail is kept only where it teaches something general.

Honesty labels used throughout:
- **Proven**: confirmed by the player in the headset.
- **Measured**: seen in logs, not necessarily felt as good.
- **Inferred**: reasoning from decompiled code, not tested.
- **Dead end**: tried, did not work.

Companion files are in `reference/` next to this file (the full original docs, a few source files to copy from, and the build script). Paths like `reference/STEREO-FEASIBILITY.md` refer to those.

---

## 0. Ten-minute summary

1. **Shape of the mod.** A native DLL injected into the game process hooks `IDXGISwapChain::Present`, runs an OpenXR session on the game's own D3D11 device, copies each rendered frame into per-eye swapchains, and overwrites the game's camera every frame with the headset pose. A thin script layer (Python in our case) handles game logic and talks to the DLL.
2. **The hard problem is stereo.** A flat game renders one view per frame. We tried four ways to get two eyes and shipped the one that survived measurement (section 3.4). Pick your approach early; it shapes everything else.
3. **Head tracking quality is a timing problem.** Read the pose as late as possible, tag every pose request with a sequence number so you know which pose each picture was drawn with, and hand the compositor the pose the picture was actually drawn from (section 3.6).
4. **Reverse engineering is most of the work, so build the tooling first.** A full Ghidra decompile of the exe, indexed by RTTI class names, string references and vtable slots, saved us weeks (section 11). A central address table with byte signatures makes a game patch a one-hour job instead of a day (section 4).
5. **UI is the second hard problem.** Flat games draw menus into the backbuffer. You need to either capture the UI separately and put it on a quad, or redraw it yourself. We chose to redraw (rule: never crop the game's rendered UI) and kept a crop fallback for rare screens (section 9).
6. **Shaders can be patched at runtime** by hooking `CreatePixelShader` and rewriting the DXBC. This is how we added a flashlight to the game's own lighting and made plants bend around the player (section 5).
7. **Make the AI able to debug without the player.** Always-on logs with millisecond timestamps, a one-button "mark" that saves a screenshot plus a log marker, a flight-recorder ring buffer, and a crash recorder. The player only says what they saw (section 12).
8. **Process matters as much as code.** One change per build, one build per test, the AI reads logs itself, GitHub branches into a dev branch, one build thread, one install thread (section 13).
9. **Expect the runtime link to be the weak spot.** On Quest through Virtual Desktop, `xrEndFrame` can block for 100+ ms when the stream backs up. Bound every wait, end sessions cleanly, log which call hung (section 3.8).
10. **Read the "Pitfalls" section (14) before writing code.** Most of the multi-day bugs are listed there with their causes.

---

## 1. Context: what was built and with what

| | |
|---|---|
| Game | The Sims 4, DX11 (`TS4_x64.exe`), PE stamp-gated builds (1.128 then 1.129). DX9 was abandoned after a week; DX11 only. |
| Headset | Quest 3, PC streaming via Virtual Desktop (VDXR OpenXR runtime). SteamVR also tested early. |
| PC | i7-13700K, RTX 4080 Super, Windows 11. |
| Language | C++17 DLL cross-compiled on Linux with MinGW-w64 (posix threads) and CMake; Python 3.7 script mod (the game's embedded version). |
| Libraries in the DLL | OpenXR SDK + loader (Apache-2.0), MinHook (BSD-2), Dear ImGui (MIT, for our own HUD), FidelityFX FSR1 (MIT). Steam Audio 4.8.1 in the sound mod (Apache-2.0). |
| Mods | Sims4VR (the VR mod) plus standalone companions: Extended Sound Control (3D sound), Realistic Lighting (night/room darkness via shader patch), Integrated Body Physics (jiggle), Claude Performance. Companions are separate DLLs on purpose (section 13.6). |
| Repos | `masterroshihehe/sims4vr`, `.../sims-4-extended-sound-control`, `.../sims-4-integrated-body-physics`. |
| Size | ~200 source files in `src/`, `vr.cpp` alone ~6,900 lines (split into 19 `.inc` parts, see `reference/CODE-MAP.md`). |
| Development model | 100% AI-written. The human is director and tester: decides what to build, tests every build in the headset, reports what they saw. |

What the mod does (as a feature checklist, so you know the scope that was reachable): stereo VR in the game's normal camera and in a true first-person mode; free stick locomotion with room-scale; the avatar's body under the headset with arm IK and finger curls; hand tracking; grab/touch/laser interaction; pie menu at the hand; wrist HUD; phone and tablet as UI hubs; menus drawn on the objects they belong to; collision of body, head and hands with walls and objects; mirrors and water reflecting your body; 3D binaural sound; realistic darkness; flashlight; foliage reacting to your body; a debug/settings menu operated in VR.

---

## 2. Decision checklist for a new game

Answer these first. Each links to the section that helps.

1. **Engine and graphics API?** DX11 is by far the easiest (vtable hook, runtime shader patching, simple shared textures). DX12 and Vulkan need different plumbing; look at `praydog/REFramework` and `UEVR` for DX12 (section 15). DX9 needs a bridge to DX11 (a D3D9Ex shared texture opened on your own D3D11 device); we planned it and never built it.
2. **Does the game already have a first-person camera?** If yes, driving it is far simpler. If not (our case), you are building a controller, a body and an interaction model, not just a camera.
3. **How is the camera stored?** Find the one function that copies the camera into the renderer's copy (we hooked that). Everything else (mirrors, shadows, culling) derives from the copy (section 3.3).
4. **Single-threaded or multi-threaded rendering?** Modern engines record command lists on job threads and present on a submission thread. Your Present hook runs on the submission thread, not the game thread (section 3.2).
5. **Script layer available?** Python in the Sims was a gift for game logic and API access (routing, object queries), and a trap because the embedded interpreter had no `ctypes` (section 14).
6. **Anti-cheat / online?** Not a problem for the Sims. For any online game with anti-cheat, stop here; injection will get players banned.
7. **Mod manager and file locations.** Runtime-created files may be redirected by the player's mod manager. Find out where logs really land (section 12.1).
8. **Licence and community stance.** EA allows free, non-commercial mods; DLL injection is a grey area. We stayed free and open-source, MIT. Check before you promise anything to players.
9. **Player's hardware loop.** We had one tester with one headset. Everything is built around one-change-per-build and AI-read logs because the tester's time is the scarce resource.

---

## 3. Architecture

### 3.1 Injection and loading

- **Goal**: get the DLL into the game process before the game creates its D3D device, or at least before the first `Present`.
- **What we did**: a Python script mod (`.ts4script`) is loaded by the game's embedded interpreter. It imports the DLL **as a Python extension module** (`PyInit__sims4vr` exported by `sims4vr.dll`; the Python C API is resolved with `GetProcAddress` from `python37_x64.dll`) using `importlib.machinery.ExtensionFileLoader`. This was forced on us: the game's Python ships **without `_ctypes`**, so `import ctypes` fails and the first script mod silently never loaded (a day lost, see section 14).
- `DllMain` does nothing heavy. The script calls `s4vr_init`, which installs hooks in a fixed order (order matters; later hooks assume earlier ones).
- **Generic alternatives** for a game without a script layer: an ASI loader / proxy DLL (`dinput8.dll`, `version.dll`, `d3d11.dll` proxy), Ultimate ASI Loader (MIT), or a launcher that suspends the process and injects. Hook collisions with other proxies (RTBP, ReShade) are a real risk: two plugins detouring the same address crash the game. We documented "who owns which address" and never hooked an address a companion mod hooks.
- **Game-version gate**: the DLL reads the exe's PE timestamp ("stamp") and only enables address-dependent features for known stamps (section 4).

### 3.2 Present hook and the frame loop

- Create a throwaway D3D11 device + swapchain on a hidden window, read `vtable[8]` (`Present`) and `vtable[22]` of `IDXGISwapChain1` (`Present1`), destroy the throwaway, and MinHook those two addresses (`src/d3d11_hook.cpp`). Vtable layout: IUnknown(3) + IDXGIObject(4) + IDXGIDeviceSubObject(1) puts `Present` at index 8.
- Handle both `Present` and `Present1` (flip-model swapchains use `Present1`, which can call `Present` internally; a thread-local re-entrancy flag avoids double work). Ignore `DXGI_PRESENT_TEST` calls (occlusion queries, not pictures).
- **The Present hook runs on the game's submission thread**, not the game thread. Since the engine records into deferred contexts on job threads and a submission thread executes command lists then presents, anything you do in the hook must respect that. Our hooks into game code (the camera copy, skinning, culling) run on other threads: use lock-free seqlocks or small mutexes, and document which thread each piece runs on. A mutex taken twice on one thread (a camera function called from inside a function already holding the pose lock) froze the game for days of builds; the rule became "code called from `applyEye` never calls anything that takes the pose mutex."
- **Per frame in the hook** (`vr_parts/18_stereo.inc renderStereo`):
  1. `xrWaitFrame` / `xrBeginFrame` (we do them at Present; the headset's refresh clock paces the game, 72 Hz).
  2. `xrLocateViews` for the display time.
  3. Copy the finished backbuffer region into the current eye's swapchain image (`CopySubresourceRegion` or an FSR/sharpen pass), `xrReleaseSwapchainImage`.
  4. Decide the pose and eye for the **next** game frame and hand it to the camera hook.
  5. `xrEndFrame` with the layer(s).
- **Own passes inside Present** (sharpen, FSR, body layer, eyelids, warp) swap in and out their own D3D11 state on the game's immediate context and restore it afterward. Plumbing is in `src/sharpen.cpp`.
- **OpenXR on the game's D3D11 device** (`XR_KHR_D3D11_enable`). You must create the session with the same adapter the game renders on.

### 3.3 Camera override

- The renderer's camera object is filled by a "copy camera" function once per frame. We located it by a byte pattern 46 bytes into the function (unique in the exe; the earlier convexvr mod hooked the same function, which is how we found it) and detour it (`camera.cpp hookedCopy`).
- After the original copy runs, the hook **writes the headset-derived pose into the renderer camera's fields**: position, right/up/back axes, and the frustum fields. Camera layout learned by RE: size at `+0x14/+0x18`, near/far `+0x24/+0x28`, view rows at `+0x30`, projection at `+0x70`, view-projection at `+0xf0`, inverse at `+0x1b0`, off-centre "frustum centre" float2 at `+0x1f0`, sub-rect fractions `+0x270..+0x27c`.
- **Rule: write FIELDS, not derived matrices.** The engine recomputes the projection from fields every update. If you patch the projection matrix instead, the mirror camera, shadow cameras and cull cameras (all derived from the main camera's fields) get the old values, and you see objects pop and mirrors lopsided (section 6, `reference/mirror_camera.md`).
- **Exact per-eye FOV** (`[stereo] exact_fov`): headset eye FOVs are asymmetric (inner side narrower). The game's projection builder supports an off-centre frustum through the `+0x1f0` centre, so you can submit the exact FOV with no patch. Before this we rendered a symmetric frustum covering the wider side and about **a third of every eye image was thrown away** (2408x2472 rendered where 1936x2074 was shown). Measured cost saved: roughly 19-24 percent of pixels per axis.
- **The camera copy runs on the game thread**, ahead of Present by up to a frame. A small queue (`g_queue[4]`) of "what was rendered with which pose" hands results from the game thread to the Present thread (section 3.6).
- **Find the camera by experiment first.** Before the hook, we shipped a `vr.findcamera` console command that read the camera position from the game's script API and searched process memory for it, then probed the copy function for 3 s and logged results. That found the struct layout without a debugger. Reuse the trick: ask the game's scripting API where the camera is, then find that float triple in memory.

### 3.4 Stereo strategies (what we tried, what happened)

This is the most expensive lesson in the project. Full analysis: `reference/STEREO-FEASIBILITY.md` and `reference/SINGLE-VIEW-HANDOFF.md` (read the second one for the numbers).

| Strategy | What it is | Result |
|---|---|---|
| **A. Alternate eyes** | The game renders one eye per frame; Present copies it into that eye's swapchain and flips the camera to the other eye for the next frame. | Works on day one, ~32-36 full stereo pairs per second at 72 Hz. Moving things differ between the eyes and **double** (moving characters, your own hands). Paired-eyes tricks hide it partly (render the right eye from where the left was, hold the left until the right arrives, rotate-warp the older eye) but cannot fix moving objects. |
| **B. Two real passes in one frame** | Call the engine's scene-render entry twice per frame, left then right. | Probe result: main frame 13.9 ms -> 27.8 ms, 2.00 presents per frame (the engine presents inside each pass, so pass 2 waits a whole headset refresh), culling doubled. GPU share per pass already 63-82 percent. **Dead end at 72 Hz** unless render scale ~0.6 and culling/shadows reused. |
| **C. Draw-call duplication (vorpX style)** | Hook every Draw, replay into a second target with the other eye's view constants. | Rejected on analysis: too fragile across 850 packages of shaders and post passes, no cheaper. Not built. |
| **D. Depth-reprojected second eye** | One real render per frame; warp it to the other eye using the scene depth, fill holes from the other eye's last picture. | Built across 12 builds. Cheap (0.3-1.7 ms GPU), but edges, glass, alpha hair, near hands and characters never looked right ("see-through rims", "ghosts"). **No-go** per the user after 12 test rounds. |
| **E. Flat world** | Right eye = left picture rotated. | Clean and 72 fps, but no stereo depth: hands and clicks feel wrong. Kept as a comfort option. |
| **F. Both real eyes every frame (shipped default)** | Two real scene renders per frame, with the second pass set up and the first captured. Render scale 0.65-0.75, FSR1 upscale, own frame clock thread sends a frame every headset refresh. | Default since build 306. First person ran 50-65 fps, GPU 3D ~80 percent, main frame 16-19 ms. Needed: a headset frame clock thread (reproject turn since drawn), body layer renderer, texture-bias sampler swap. |

Takeaways:
- Alternate eyes is the right **first** stereo mode. Ship it, then iterate.
- Measure main-thread cost per pass **before** building a two-pass mode. We lost three builds proving the second pass doubles the main thread.
- If your engine presents inside its scene-render function, calling it twice gives you two presents. Suppress the first.
- Missing 72 Hz in a two-eye mode is **worse** than alternate eyes (Virtual Desktop halves to 36 fps and synthesizes frames). Give the mode its own render scale and an automatic fallback (GPU > 85 percent for 5 s -> back to alternate, return after 30 s under 70 percent).
- Anything that assumed one camera per frame breaks with two: picking, audio listener, near-plane depth sensor (one depth-copy slot), UI compositing. List them early.

### 3.5 Per-eye details that bit us

- **Pose used to draw must equal the pose submitted.** Each picture is drawn from a pose requested earlier. The `XrCompositionLayerProjectionView` pose must be that old pose, not this frame's located pose. Audit: pose in the layer == pose in the camera hook for that picture. Cyberpunk VR port reported 4-12 percent of frames reusing the previous epoch for exactly this reason.
- **Paired hands and eyes.** Anything per eye (hands, body, HUD) must use the pose that eye was rendered with (`g_eyePose`), not the located pose now.
- **Turn reprojection.** Snap/smooth turning with a stick changes yaw between the render and the shown moment. Keep each picture's yaw, rotate the image about the head (`eyealign.cpp` warp shader) to the shown yaw. `turn_lead` pre-compensates using the learned draw-ahead. We also moved the stick-walk and stick-turn clocks onto the headset's display clock instead of the PC clock, so every frame the player sees moves by the same step (removes sideways-walk jitter).
- **Headset frame clock thread.** Once the game dropped under the headset refresh, turning became choppy because the game frame rate gated headset frames. A thread that submits on every headset refresh using the last picture (turned by the stick since it was drawn) fixed the wobble: refreshes missed went from 5-31 per 1-2 s turning to zero most of the time. Source: `src/vr_parts/18b_frame_clock.inc` (in the repo).
- **Body layer.** First-person hands drawn at one depth look wrong with depth reprojection. We split the avatar's own body into a separate layer using the depth buffer and drew it from the current pose (mask + pull-push hole filling in `bodylayer.cpp`). Cost 0.4-0.9 ms per eye; scissored to the body's screen box.
- **Texture mip bias.** Rendering at 0.65-0.75 scale blurs textures. A `CreateSamplerState`/`PSSetSamplers` hook that swaps in a negative mip bias (-0.5 to -0.6) on wrap + mipmapped non-comparison samplers gives sharper textures; the first version hooked creation after the first Present and caught 0 samplers (the game made them earlier). Swapping at `PSSetSamplers` (immediate and deferred contexts) worked. FSR1 render scale 0.67 makes bias -0.6 about right (log2 0.67).

### 3.6 Head pose at Present with frame tags (GLA-22)

Goal: draw each picture from where the head will be when the picture is shown.

- At every Present, `renderStereo` calls `xrLocateViews` for the predicted display time, then **bumps a sequence number** and records `{seq, time}` in a 32-entry ring (`g_poseRing`).
- The sequence number travels with the pose request into the camera hook (`camera::setPoseSeq`), is stored in the queued record (`Rendered::poseSeq`), and comes back with the finished picture.
- When the picture arrives at Present, `notePictureAge` compares `g_poseSeq - rendered.poseSeq` against the **typical** age (a histogram mode over recent pictures) and classifies it **exact / older / newer / stale / gone from ring / untagged**. It logs one `Pose ring:` line every 10 s with counts, average pose age in Presents, and "shown N ms after asked".
- **Late pose** (`[stereo] late_pose`, default on): the pose requested for the next picture is predicted forward by the measured request-to-shown time (smoothed, 5 percent per sample), using a second `xrLocateViews` at the later time. Result: the picture is drawn from where the head will be, not where it was.
- The log line tells you immediately whether a new build made pose timing worse. Status at handoff: code ready, awaiting a headset test.
- Generic lesson: **tag everything that crosses a thread boundary with a sequence number and measure the age distribution.** It turns "feels laggy" into a number.

### 3.7 Latency work: `gpu_wait` and `cap_lead`

Two independent switches (both default off pending measurement; both have log lines that show their effect either way).

- **`cap_lead` (GLA-21)**: "game thread waits for Present." The game thread's camera copy normally runs up to a frame ahead of Present. With `cap_lead` on, the camera hook waits on an auto-reset event (`g_presentTook`, set by Present after it takes a picture) for at most **11 ms**, only at a frame's first copy (never between a pair's eyes), only while a picture is queued. The game then never works a frame ahead, so the head pose it reads is fresher. Stats (`Lead cap: waits, timeouts, avg wait`) go into the Stereo log line. Cost: possible small fps drop when the game is the bottleneck.
- **`gpu_wait` (GLA-118)**: "Present waits for the graphics card." A D3D11 `D3D11_QUERY_EVENT` is issued after each frame; before the next, Present spins (`YieldProcessor`) on `GetData(..., 0)` for the **previous** frame's query for at most **12 ms**, so at most one frame is queued on the GPU. Aims to cut the delay between moving the head and seeing it; can lower fps slightly. Logs `GPU wait ON: Present waited X ms on average ... N of 500 timed out`.
- **`gpu_yield`**: give the game below-normal GPU priority while the headset view is on (`IDXGIDevice::SetGPUThreadPriority`), so the streamer's encoder always gets the card in time. A game that fills the card starves the encoder and the link jams.
- **Where the latency actually was** (measured): GPU "frame done" 16-25 ms after submit; Virtual Desktop encode + stream + decode on top gave a user-reported ~50 ms total. The game's own present is locked to the headset's `xrWaitFrame`. Raising headset refresh to 90 Hz means 45 stereo pairs per second at ~70 percent GPU (estimated from 55 percent at 72).
- **Quick wins we listed but did not all get to**: write the pose into the camera as late as possible (late latching at camera copy), `XR_KHR_composition_layer_depth` (depth already copied), hidden-area mask (`XR_KHR_visibility_mask`; VDXR does not offer it), fixed foveation via NVAPI VRS (NVIDIA only).

### 3.8 Runtime link stalls (Virtual Desktop) and clean session handling

Full code: `reference/vd-freeze-handoff.md`. Short version, as rules:

1. **No infinite waits.** `xrWaitSwapchainImage` with a 0.5 s timeout. After `XR_TIMEOUT_EXPIRED` do **not** acquire again (the image is still acquired); re-wait the same index next frame and leave that layer out of `xrEndFrame`.
2. **Watchdog thread for calls you cannot bound** (`xrWaitFrame`, `xrEndFrame`): a timer object wraps each call, a thread logs "stuck in <call> for N s" once a second. It cannot unstick anything, but it separates "runtime dead" from "game dead" instantly.
3. **Stall = runtime held a frame > 80 ms.** Recovery needs **1 s of smooth frames** (one fast frame during a crawl must not reset the clock). A stall of 12 s ends the session cleanly, then reconnects with backoff (5, 10, 20, 40, 60 s).
4. **End sessions the OpenXR way**: `xrRequestExitSession` -> wait for `XR_SESSION_STATE_STOPPING` -> `xrEndSession` -> `xrDestroySession`. Never end or destroy a RUNNING session; Virtual Desktop's own log said `xrEndSession failed with XR_ERROR_SESSION_NOT_STOPPING` and the streamer then needed a restart in the headset. Fall back after 3 s if STOPPING never comes.
5. **Destroy the session before process exit.** Leaving it to process teardown crashed inside VD's threads.
6. **Persist settings on change** (autosave 1 s after a menu edit), because a freeze loses unsaved tweaks.
7. **Log at stall onset**: layers sent (type + pixel size), optional features active, GPU lag, video memory.
8. **Read the runtime's own log right after a freeze** (VD: `C:\ProgramData\Virtual Desktop\OpenXR.log`, only the last OpenXR app). VD's virtual audio device vanishing from Windows is a reliable "VD lost the headset" timestamp.
9. **SteamVR's idle throttle looks different**: both `xrWaitFrame` and `xrEndFrame` exactly 100 ms. Do not treat that as the VD stall.
10. Root cause of the VD freezes was **never proven**. Ruled out: video memory, HAGS, boost priority, HEVC 10-bit, lower preset. Open suspects: total pixels per frame including extra quad layers with their own swapchains, extra MSAA targets, Wi-Fi, encoder bitrate. Check yours with the logging above.

---

## 4. Surviving game updates: the address table

Problem: hard-coded RVAs (165 of them in 27 files) meant every game patch turned off every stamp-gated feature until someone remapped by hand (a full manual remap for 1.121 -> 1.128).

Solution (built 2026-10-19): `reference/EXE-INDEX-README.md` section "Game addresses in the mod".

- One TSV (`tools/addrs_src.tsv`): name, kind (function/global/vtable), rva, used_in, first 16 bytes, signature, description. `tools/gen_addrs.py` turns it into `src/addrs_table.inc` with an RVA and a **masked byte signature** per function (relative operands wildcarded) and an **anchor** per global (a function that reads the global RIP-relatively).
- At startup `addrs::fn("Name")` / `addrs::global("Name")` resolve rows: check bytes at the table RVA; if they differ, try a unique signature scan of `.text`; if unresolved or ambiguous, log one line and return null so the feature stays off. Globals/vtables check the exe stamp gate; an anchor's value wins over the table.
- On an unknown exe stamp, nothing is used, but the log lists `Name: 0xold -> 0xnew (by signature)` for every function a scan finds, which **is the remap list**.
- **After a patch**: stage the new exe, `rtti_index.py` rebuilds the class index (~2 s), `gen_addrs.py --remap --write-src` moves every row by signature and prints PROBLEM rows for hand-fixing, then rebuild. Keep the old stamp folder for diffing (class vtables move, names don't).
- **`sims4vr_patch_report.txt`** is written on every start: stamp, size, section readability, every table row (table RVA vs where the signature puts it), features on/off, RTTI lookups with fallbacks, MinHook results, and log-only plausibility probes (camera and input layouts). A run that does not reach 120 s leaves an "inflight" marker, and the next run is a **safe run** (nothing from the table) so a bad patch cannot crash-loop the game.
- **Prefer RTTI class names over RVAs** where possible. The game's exe had RTTI; `rtti::findVTable(".?AVCameraControllerManager@ClientApp@Sims4@EA@@")` survived patches. When names go missing (build with stripped RTTI), anchor vtables on a constructor.
- Struct **offsets inside game objects** are not covered by signatures. Re-check them after every patch (the decompile rule below).

---

## 5. Shader reverse engineering and runtime patching

### 5.1 Getting at the shaders

- The Sims 4 stores precompiled DXBC in `Shaders_DX11.precomp` (80 MB, 37,960 blobs). Blob format: 44 raw header bytes, body in Snappy-style tokens, window includes the header, decompressed size at header +24. The exe's Snappy decode is at a known RVA (the shader decode is the same family as the string path). 1,592 blobs were not decoded. **Hash-to-blob mapping was never solved**, so we match shaders by *content* at creation time, not by name.
- RDEF (reflection) is stripped: you only know register slots, not variable names. We recovered meaning from the input signature, instruction pattern, and how the CPU side fills the constant buffers (tracked in the decompile).
- Decode all blobs to disassembly once (`disasm_all.txt.gz`), grep for patterns (e.g. "sample_indexable texturecube"), and keep decoded copies. Tools: our own decoder scripts, plus vkd3d's `vkd3d-compiler` and `spirv-val` as offline validators (a patched blob that vkd3d compiles and spirv-val accepts is very likely valid).

### 5.2 Runtime patching pipeline (proven pattern, used 3 times)

1. **Hook `ID3D11Device::CreatePixelShader` (vtable slot 15) or `CreateVertexShader`** using a vtable read from a throwaway device (same trick as the Present hook). Install it before the first `Present`; shaders created earlier are missed (the log must say how many were "made after the first Present"; if zero, the hook is too late).
2. In the hook, check the blob with a **pattern matcher** (not hash). If it matches a known family, **rewrite the DXBC bytes**: add a constant buffer declaration, extra temps (`dcl_temps`), the new instructions, adjust the shader header's size fields, **recompute the DXBC checksum** (the container hash is a custom MD5 variant; do not skip it, the runtime refuses bad ones).
3. Hand the game the patched shader; keep a lock-free map patched -> original. If `CreatePixelShader` refuses the patched blob, fall back to the original (a bad patch degrades to "feature off", not a crash). **A patch that is accepted but wrong draws wrongly**, so always ship a settings row to turn it off (restart required).
4. Hook `PSSetShader` (immediate and deferred contexts) so that when a patched shader is bound you also `PSSetConstantBuffers(slot, ours)` on that context. Unbound slot = zeros = effect off.
5. Per frame on the Present thread, `Map(DISCARD)` the buffer and write the new constants (positions, colours, flags).
6. Write the patcher as **pure functions over bytes** (`src/beampatch.cpp`, `src/foliagepatch.cpp`) with an offline test harness (`tools/test_foliagepatch.cpp`: `./tfp in.dxbc out.dxbc`), so it can be validated in the cloud with no game.

### 5.3 Worked example: flashlight inside the game's lighting (`reference/FLASHLIGHT-PS.md`, `reference/FLASHLIGHT-BEAM.md`)

- First attempt: a screen-space pass on the final 8-bit image. Failed in dark scenes: near-black pixels have no colour left to light.
- Fix: make the beam one more light **in the game's own light sum before the 8-bit store**.
- For the object ("phong") shader family: inputs include a world normal and an **unnormalised world-space vector to the camera** (the PS has no eye position, but it has this vector). The final instruction is `mad o, albedo, light, specular/env`. The patch adds `cb13[4]` (position, direction, cone, colour, range), 4 temps, and `if_nz cb13[2].w { cone ramp; (1 - d/range)^2; 1/(1 + d^2/r0^2); 0.3 + 0.7 N.L; beam = colour * factor }`, then `light' = light + beam` used as the `mad`'s light operand. Camera-relative math means no extra matrices.
- Sims-like shaders have world position in the PS and three built-in point lights; the plan there was CPU-side (replace the weakest of the three).
- **Not covered**: terrain/walls without a cube, particles. Caveat: "UNTESTED in game when written; no real shader blob was available in the cloud". Make a way to get real blobs into your offline harness early (`device_stage_files`).

### 5.4 Worked example: reflections that ignore light (`reference/SHINE-IN-DARK.md`)

- Shiny things stayed lit in pitch black. The decoded phong shader: `final = diffuse * (lights + ambient) + (sunSpec * shadow + cube(R) * tint) * specColour`. The cube term has **no light, ambient or shadow factor**.
- Swapping the global default spec probe texture did nothing: materials bind their own cube. 13,381 of 37,960 pixel shaders sample a cube.
- Fix: a DXBC patcher that finds the final `mad colour, light, albedo, shine` **by data flow** (the addend depends on a cube sample; the factors do not; the light is the factor that went through `rsq` or `dp3_sat`) and scales the shine by `lerp(1, saturate(lum(light) * 4), strength)`. Result: 10,626 patched, 1,552 ambiguous (light and albedo indistinguishable), 1,203 with no recognisable form. All patched checksums valid; a 63-shader sample compiled with vkd3d.
- Lesson: **data-flow matching beats hash lists** when you cannot map names to blobs.

### 5.5 Worked example: vertex-shader push (foliage) (`reference/FOLIAGE-PUSH.md`)

- Recognise wind shaders (one `sincos` plus reading the frame-time cbuffer), find the wind add (`mad rA.xyz, v, cb0[n].xxxx, rA.xyz`), add a push away from 8 spheres (head, chest, hips, hands, nearby characters) weighted by the game's own bend weight. Two families (static and instanced). Dedicated cbuffer slot 6 (9 rows). `if_nz cb6[8].z` wraps it. Each wind shader is created twice (patched and original); with the setting off the original is bound, so nothing differs from vanilla.

### 5.6 Lighting constants and day/night

`reference/CB7-LIGHTCBUFFER.md` and `reference/LIGHTING-DESIGN.md`:

- World lighting sits in one constant buffer (`LightCBuffer`, cb7: sun colour, sun direction, two ambients, derived), **bound by pointer to live memory** and rewritten every frame by the renderer (a one-shot write is overwritten). The right way to scale it: post-process the writer's output (hook the function that fills it, or wrap the curve evaluator for the channels 6, 7, 0xd that feed it).
- Many months of "nothing changes at night" came from scaling the sky channels that only feed the sky picture, not the world. Find which curve channel feeds which cbuffer field **by logging both**.
- **Compatibility rule that paid off**: do not ship a data package that overrides the same tuning instance as other lighting mods (only one wins). Apply a multiplicative adjustment at runtime on top of whatever loaded, restore on off, and never scale below x0.03 (a zeroed light baked a black lightmap tile that stayed bad until the light was rebaked).
- Baked lightmaps are recomputed when certain tuning fields change (sun heading/pitch callbacks invalidate every lightmap); that is how we made window sun follow the real sun, and also why you must change those in 15-degree steps, not every frame.
- Sun shadows "ticking": the sky deliberately passes a stepped sun to the shadow code; wrapping the provider to copy the smooth direction into the stepped slot fixed it (`re/shaders/SUN-SHADOW-STEPS.md`, not copied here).
- Shadow quality in VR: hook the config getter to give 4096 instead of 2048 shadow map while the headset is on, texel-snap the shadow fit, pull the near cascades closer in first person.

---

## 6. Reflections per eye

`reference/REFLECTIONS.md`, `reference/mirror_camera.md`.

- Planar mirrors and water in this engine are **real re-renders** from a reflected copy of the main camera (position and axes reflected across the plane, own far plane, own render target), culled on job threads like shadow cascades. Cube-map probes cover shiny floors/glass (no moving characters in them).
- Because the mirror camera is **one bulk copy of the main camera's fields** at pass time, writing per-eye values into the fields (section 3.3) gives each eye a correct mirror with real parallax, for free. Your own body shows in mirrors because the mirror camera has its own near plane (our near-plane push and eye inset only touch the main camera).
- **Bugs we hit and why** (all from `mirror_camera.md`):
  - Mirror selection uses ONE camera position (the main camera's), so a mirror can flip in/out between eyes. Hysteresis or a larger fade radius fixes it.
  - A separate **cull camera** is narrowed to the mirrors' projected box and re-centred with a look-at; the eye's lens shift (`+0x1f0`) made it cut one side per eye. Fix: zero the eye centre in any non-eye camera whose look-at flag is set (the look-at flag at `+0x280`, not a glass-clip flag as first assumed).
  - The first fix patched the projection output for the main camera only; mirror cameras rebuilt from centred fields and objects popped depending on mirror/eye position.
- Things you draw yourself (phone, HUD, laser) are absent from mirrors; things the game attaches itself (a held remote via the game's prop system) show. Plan around that.
- Cost: every mirror/water pass runs per eye (or per frame in both-eye mode). Give them a switch and a distance threshold in your settings.
- Blue-skinned character in a mirror for half a second at night: traced (inferred) to a route snap placing the body 2 s ahead outdoors; the mirror pass picked up that spot's lighting. Moral: whatever you pin or teleport, do it consistently across passes.

---

## 7. Collision via navmesh (and why we moved past it)

Full plan with probe results: `reference/COLLISION-PLAN.md`.

- **Stage 1 (shipped, still the fallback)**: 24 ray tests (`routing.ray_test` through the game's navmesh) at 0.4 m every 0.1-1 s from the script side, forming a "blocked directions" mask that limits stick velocity only. Cheap to write, but 2D, coarse (15 degree rays), late (10 Hz), and **cost spikes of 23-67 ms** because `ray_test` waits on the game's path planner thread. Mitigation: reuse the last result up to 0.3 s while a plan is in progress.
- **Stage 2 (built; phases tested up to head + hands)**: a local **collision scene**: the script gathers simple shapes within 8 m (wall contour segments with height ranges, object footprint prisms with heights, oriented boxes from model bounding boxes for wall-mounted things) and sends them as flat float arrays; the DLL builds a 0.5 m uniform grid and tests a body capsule (radius 0.3 m, step height 0.3 m), a head sphere, and per-hand shapes every frame. Response: **push + fade** (eased push capped at 0.25 m; deeper penetration fades the view until you step back, no push).
- Key facts that generalise:
  - Games usually expose wall contours, footprints and heights through their navigation API. **Probe first** (our `probes/p18_collision.py`): for the Sims, `get_wall_contours` returns every wall on the level (183 contours in 0.06 ms), one closed 0.23 m thick outline per wall piece with `False`.
  - No physics engine existed in the exe (picking is a GPU id-buffer for the cursor; build-mode placement helper only). You will likely write your own. Candidates: Jolt (MIT), our own capsule/segment tests (enough).
  - Let the head lean over a counter (test y-range of shapes against eye height) but not into a wall cabinet. Body radius, step height, head radius should be settings.
  - Rebuild the scene on events (navmesh build id changed, wall-contour callback, object added/moved within 8 m, 3 m from last centre, level change) with a 1 s hash backstop, and batch object rebuilds (~20 per 0.1 s tick) so no script tick stalls.
  - Hands: the drawn hand stops at the surface while the real hand continues, and catches up on pull-back. Haptics off by default (the user did not want vibration).
  - Soft things (plants) slow the stick instead of blocking (flag-based, name/tag matching). Alpha cut-out leaf meshes are collision-soft; opaque bush planter edges are solid.
  - Teleport targets still go through `test_point_placement_in_navmesh` so the server-side avatar never ends up where the game cannot route.
- Build-mode edits leave the navmesh stale until build mode exits; rebuild the scene from contours on placement.

---

## 8. First-person body, locomotion and interaction

Detail: `reference/HAND-RIG.md`, memory-derived notes below, `reference/RULES.md`.

- **Do not drive movement through the game's routing.** First attempt used GoHere routes; it fought the player (select sound, walk-back after release, walk animation continuing after stop, server avatar lagging 17 m behind). The mandated architecture: our own player controller (`player.cpp`) with stick walking, snap/smooth turn around the head, floor plane from the script side, wall mask; the avatar's actor is `SetTransform`ed under the headset each frame (faces walk direction when moving, head direction with 35 degrees slack when standing). The script side only **reports** (is free movement allowed, ray mask, terrain plane) and teleports the server avatar with `move_to` every second and on stop.
- **Make the animation play without a route**: the script mod sends client-side route operations (`FOLLOW_ROUTE`, `ROUTE_UPDATE`, `ROUTE_CANCEL`) built from the player's path and exports velocity to the walk pose. Stopping needed a native `walkstop` that force-stops the client route, plus cutting the path at your feet, because the walk animation otherwise kept playing after you stopped.
- **Body split rule** (user): head = headset only; hands = player (IK); torso and legs = game animations. Hands and head follow the player **also during the game's own animations** (seated, etc.).
- **Arm IK** (`armik.cpp`): hook the function that converts the animation pose to model joints (called per actor per frame), then for the player actor only rewrite UpperArm/Forearm/Hand local quaternions (two-bone IK, elbow pole down/out/back, 60 percent of the wrist twist in the forearm) and finger joints (bind pose + curl about cross(finger, palm)). Joints addressed by FNV-1 hash of lowercase names (`b__R_Index0__`). Hand axes derived from bind finger positions, so a different skeleton needs only names. Inputs: grip pose action, trigger value + touch, squeeze, thumb touch (stick/thumbrest/A/B/X/Y). OK-sign thumb uses CCD toward the index tip.
- **Held objects keep the game's finger grip**: the script reports candidate prop ids; a hand counts as holding when a candidate exists and the game's animation curls middle/ring/pinky > 0.6 rad (`armik::gameCurl`). Prop root joints reported (0,0,0) so a world-position check failed; use the curl criterion.
- **Hand tracking** (`XR_EXT_hand_tracking`, 26 joints): per-joint bend from relative orientations, hand pose from palm orientation + quarter turn + offset; a controller in hand always wins; tracked hands are "looks only" (no pokes/grab/laser) until proven. VDXR advertises the extensions; the mapping was never seen live at the time of writing. Quest 3 has **no eye tracking** (design: eyes follow where you point).
- **Hand shape capsules** (`handshape.cpp`, `bodyshape.cpp`): palm + finger segment capsules from the posed skeleton right after the game's PoseToJoints, carried by the live controller pose; body/head/hair capsules of the player and nearby characters. Used for laser hits, pokes, touch, gestures, grabbing, collision.
- **Near plane and near fade.** The engine hides objects when the camera is inside their bounding box (a fixed margin on the active lot) and fades close objects; we hook the hide function to always return visible and clamp the adaptive near plane. The near plane is computed from a **GPU reduction of the scene depth** to the nearest point each frame, excluding your own body. Your view sits 2 cm inside the avatar's head and the near plane is pushed past the head so you never see teeth or eyeballs from inside.
- **Eyelids**: sleeping/napping closes lids and darkens (never on blinks); `eyelids.cpp` + a pass in the sharpen shader, driven by a script-side state.
- **Walls/floors kept visible**: engines often drop "walls up" or floor-override state on camera moves. The mod re-applies the lot override every 0.5 s when it drifts.
- **Doors need no interaction**: open at 0.9 m from the doorway centre line, close beyond 1.4 m by replicating the client portal-enter/exit events (not by script interactions); arches get a 0.3 m rail cleared from the ray mask.
- **Interaction rules we adopted** (user-driven; copy the idea, not the specifics): no scripted actions for the player's avatar, interactions only within about 1 m of the target (silent otherwise), no auto-pathing, autonomy off in first person and restored exactly on exit, game speed never changed by the mod, first-person-only gameplay hooks gated on a single `bodyActive()` check.
- **Robustness**: free movement must handle teleports, level changes, stairs (rails on flights, sides push the head back), and the avatar being moved by the game (seated, carried). Each of those was a separate bug.

---

## 9. UI and menus in VR

References: `reference/UI-KIT.md`, `reference/ui-techniques.md`, `reference/EXE-INDEX-README.md` (Scaleform section).

### 9.1 Getting the UI out of the frame

- The engine draws its UI (Scaleform GFx, Flash) **after** the scene into the same backbuffer on a job thread. We hook `OMSetRenderTargets` and `ClearDepthStencilView` on immediate and deferred contexts (`uihook.cpp`, slots 33 and 53) to learn which target is the **scene** target (colour + depth) and which is the **UI** pass, and call the engine's own UI render function once a frame so we know when the UI begins. In first person the UI is **not** composited into the eye image; it goes on its own layer.
- In the engine's gfx wrapper, the structure offsets that matter for this (main colour target at `+0xd0`, deferred context at `+0x1d8`, parent at `+0x250`) **moved in every patch**; check them after each update.
- To draw into the scene (phone, pie menu, held props) we bind the scene's colour + depth ourselves and, in depth-reprojection mode, write depth for every piece. Note the copy of scene depth is recorded in the UI's deferred command list **once per Present**; if two UI frames record before a Present, the second has no copy.

### 9.2 Interaction model

- **Laser pointer** (grip + A/X in first person; pulling trigger clicks) maps a ray to a UI quad's pixels and sends **real scan codes** to the game (`pointer.cpp`). Extended keys need the E0 flag: Page Down once went out as numpad 3 and changed the game speed to 3. Use a `SendInput` wrapper that sets `KEYEVENTF_EXTENDEDKEY` for the extended set.
- **Pie menu at the hand**, **own pie by poking the stomach**, **wrist menu** (`vr_parts/07,08,11`), **phone** as the hub, **menus drawn on their object** (a game menu on a fridge or TV is never larger than the object and closes when you walk away, TV menus stay).
- **Popup cards in the world** (dialogs as cards, two-character chat with portraits) and **speech/thought balloons in 3D**.
- Debug/settings menu in VR (`B` button): nearly every setting changes live and is saved on change to a user ini that wins over the default ini; hover tooltips from a table; a "Developer options" switch hides rows meant only for testing in a public build (`.dev = true` per row). Every standalone mod gets its own submenu there from its first build, because **all testing happens in the headset**.
- **Hand-menu rule**: any UI element uses the pie recipe: own drawing + pose fixed in app space when shown, placed into the world per drawn frame. **Never** make a card re-follow the player after walking 1 m unless asked (we got it wrong twice).

### 9.3 Draw it yourself vs crop it

- Rule from the user: **never crop the game's rendered UI onto VR elements.** Find how the game draws each element (Flash in the decompiled UI, art atlases, thumbnails, layered parts like the side-action badge) and draw it natively (Dear ImGui + a `uikit` of pieces: 9-slice panels, discs, rings, badges, portraits, tooltips; art packed by `tools/pack_hud_art.py` into an atlas).
- A few screens still used a crop fallback (pickers whose strings cannot be built, the vanilla options menu, build/buy tiles). That is acceptable as a fallback if it is isolated and flagged; plan for it from day one.
- **Ask the engine for strings and data, not pixels.** We hooked `UiDialogService.dialog_show/respond/cancel`, the notification distributor, the money update, `GameClock.push_speed` etc. in Python (`hooks.hook(...)`, section 13.7) to build our own UI from the same data the Flash UI receives.
- **Scaleform RE notes** (1.128 RVAs in `EXE-INDEX-README.md`): a value is a 0x20-byte struct `{ObjectInterface*, type (mask 0x8f), data}`; `Movie::Invoke`, `GetVariable`, `SetText` entry points; the UI manager global and its `Update` slot. UI talks to the game only through **named services** (`CallGameService`) and messages; an index of services is in `buildui/native_services.tsv`.
- UI mods that override a whole SWF pin an old copy of the game's UI code and conflict with each other (last loaded wins); prefer runtime changes from C++/script over shipping a SWF override; a patched `*Tunables` constants file is the smallest safe override. Tools: JPEXS FFDec CLI to decompile/export, own DBPF reader.

### 9.4 UI details that cost builds

- **Unproject for a quad, not for a screen**: laser/pick math must use the exact per-eye FOV centre when `exact_fov` is on (our picks were offset until we fixed the near-plane check, phone drawing and picks to take the centre).
- Hands at the bottom edge of the view disappeared with FSR + body layer when looking down with the eyes (open at handoff).
- UI text sharpness: draw fonts at the layer's native pixel size, not scaled; Flash fonts and our atlas fonts need separate scale constants (`bubbles::stageScale`).
- Per-frame GPU waits and readbacks in HUD/screenshot paths cost fps (Cyberpunk VR port: a per-frame fence wait cost 43.8 vs 70.3 fps). Make diagnostics opt-in; use non-blocking `Map(DO_NOT_WAIT)`.

---

## 10. 3D sound (Steam Audio HRTF, occlusion, reverb)

Source: the standalone Extended Sound Control repo, `reference/SOUND-FEASIBILITY.md`, `reference/SOUND-NEEDS-TESTING.md`, `reference/RESEARCH-VALVE-TOOLS.md`.

- **The game's audio engine is in the exe** (EA::Audio::Core: a plugin graph `SamplePlayer -> Gain/GainFader/Pan3D/filters -> SubMix -> Compressor/Limiter -> Dac`). Most sounds (animation events, object loops, ambience, music, UI) **never pass through the script layer**, so a script-level sound mod covers a minority. Find the engine's classes by RTTI (mangled names via `rtti::findVTable`) and hook the plugin processing.
- **Listener**: hook the function that sets the audio listener from the camera and feed it the head pose. The game lerped between camera and look-at point (right for a god-view camera, wrong for ears inside the action). In first person the listener must be the head.
- **Binaural**: replace the per-sound panner (`Pan3D` block processing) with Steam Audio. Facts that took builds to learn: the panner's channel fields were **swapped** (`+0x324` is INPUT channels, `+0x328` OUTPUT); voice buses are always **8-channel** whatever the game's output mode; so take mono sources, write the binaural pair into the bus's front-left/front-right (channels 0 and 2 for 8-channel; 0 and 1 for 2/4/6), silence the rest, and set the game's output to **Stereo** so its own fold-down passes it through (in the game's own "Headphones/HRTF" mode it re-filters our pair).
- Angle convention: the panner's angle grows towards the RIGHT; an early negation was wrong (user: "Mirror had to be ON to be correct"). Expose a mirror setting but default correct.
- Steam Audio: load `phonon.dll` at runtime with `LoadLibraryEx` (4.8.1, Apache-2.0), one binaural effect per voice slot (256, created on a worker thread), bilinear HRTF interpolation, falls back to a built-in head model if the DLL is missing. Optional `hrtf.sofa` (SimpleFreeFieldHRIR layout) replaces the built-in set; libmysofa (Valve fork, BSD-3) could load personalised sets; elevation recognition is mostly a function of the HRTF set. Feed full 3D direction (x right, y up, -z ahead) from the VR side (`esc_set_elevation`).
- Stereo sources (music, TV) are downmixed and made binaural (`hrtf_stereo`); sounds within 1 m must **keep direction** (the game's "directness" collapsed them to head centre), setting `hrtf_close`.
- **Occlusion and muffling**: the engine has `isOccludedByWorld` and wall-distance/inside-outside curves. We hooked the inside/outside value and wall distance, read both-room-size flood fills from the script side (object count = absorption) for reverb, and fed occlusion from the VR mod (the sound mod alone cannot see sound world positions) through an exported `esc_set_occlusion`. Reverb: outdoors dry (default 15 percent), log-scale room size, eased changes, level-matched; user said the first reverb was "very unbalanced" and it was still being fixed at handoff.
- **Master boost above 100 percent**: extra gain on the master SubMix before the game's Limiter so it cannot clip. Per-category boost, compressor on master, clarity (the game low-passed 11 of 28 voices to 500-700 Hz; enforce a minimum cutoff and a high shelf).
- **Rule from the user: every sound must go through the sound mod, and always assume sounds must be 3D.** Our own added sounds (knocking, foley) play through the same panner path.
- **Never hook what the VR mod hooks**: listener, per-sound pan step, wall-distance, inside/outside, PlaySound wrapper. The ownership list is in the sound design doc. The mod stays standalone; the VR mod only feeds it via exports.
- Confirmed working by the user: binaural, Steam Audio, sound height.

---

## 11. Reverse-engineering workflow and tooling

- **Decompile the whole exe once** (Ghidra 11.4.2 headless + OpenJDK 21), one `.c` per 64 KB of RVA (136,863 functions), and build indexes from it: `classes.tsv` (every RTTI vtable, demangled name), `hierarchy.tsv`, `vtable_slots.tsv` (grep a function RVA to learn which virtual it is), `strings.tsv` (rdata strings with reference counts and the referencing functions), `functions.tsv`, `callers.tsv`. Stage the exe with `device_stage_files`, then `objdump -d` for a 270 MB disassembly for pattern searches. Details in `reference/EXE-INDEX-README.md`.
- **String xrefs are the best entry points** (options names, log strings, tuning names like `WaterReflectionDetail`). Anything reached through a table has zero refs; use vtable slots there.
- **Decompile the game's scripts as well** (Python 3.7 `.pyc` -> source with community decompilers): for us `re/python128/` was the contract for game logic; hooks go through a central helper that lists every wrapped function so an update diff is a checklist.
- **Tuning/data containers** (DBPF packages): own readers (`dbpf.py`, `simdata.py`) for the game's data; fade tuning, DOF settings and lighting settings are data you can override or edit at runtime.
- **Unity/Unreal/other engines**: the same tactic works with their tools (UEVR, AssetStudio, etc.).
- **Probe scripts**: a dev flag watches a file next to the mod and runs it on the game thread with the mod's modules in scope; output goes to `*_probe.log`. The AI writes probe scripts into the player's folder and reads answers, no rebuild, no restart. Disable in public builds.
- **Decompile rule (user, binding)**: whenever something is added or changed, **first read the relevant decompiled game files** and implement it the way the game does it; say in the build notes which files were checked. Do not guess.
- **Prove the cause from data before coding** (user rule 2026-11-04). Many of our worst bugs came from fixes built on inferred causes that logs would have refuted.
- **Gotchas**: MSVC RTTI only exists for classes with virtuals; ICF (identical code folding) makes one function appear in many classes; `windows.h` defines `near`/`far`/`close` as macros; Ghidra names are `FUN_1<rva>`; keep decompiles of **both** old and new stamps for diffing; the container may lack the hard-coded paths in your helper scripts (many of ours used `/tmp/claude-0/...`).
- **Old-version RE material may still be needed**: after a patch, features that were decompiled on the previous exe (build mode, in our case) are still best read from the old exe's decompile.

---

## 12. Testing and observability: the loop that let an AI debug a headset mod

Full text: `reference/vr-mod-logging-handoff.md`, `reference/monitoring-handoff.md`, `reference/MARK-HANDOFF.md`. This section is the summary and the order to build things in.

### 12.1 The loop

1. Player tests and says only what they **saw and felt**. They never send logs, version numbers, or times.
2. The AI pulls logs from the player's PC itself (desktop folder tools on folders approved once: list, stage, commit).
3. It correlates the player's words with log timestamps and answers **with evidence** (quote the line), fixes, builds one change, and loops.
4. **A log line is never proof a fix worked for the player.** Use it to explain, not to replace, the player's report. "Headset result outranks logs."
5. **No logging-only builds**: new logging rides along with a real fix.
6. Builds start directly in the mode under test (an ini setting), so no console commands are needed in VR.

### 12.2 Logs (build this first)

- Native log: `[hh:mm:ss.mmm] [tag] text`, local time, flushed on every line, truncated per launch with the previous two kept (`_prev`, `_prev2`). Tag = text before the first `": "` lowercased (`Arm IK:` -> `arm_ik`), or explicit `LOGT("tag", ...)`. `[log] tags=` keeps only listed tags, `mute=` drops some (`session` and `warning` always kept).
- Script log: same format; one file handle held open (opening per line went through the mod manager's virtual filesystem and caused stalls); swallow all errors; `@timed(name, limit)` decorator logs game-thread callbacks over 8 ms (first 40).
- **Startup banner** `[session]`: version, commit, game exe stamp, folder loaded from, ini switches, then a `[game_addresses]` summary. The AI never asks "which build".
- **Write sentences about the player's world**, not variable dumps: `Phone: right hand closed 0.72 m below your eyes, 0.26 m right: takes the phone out`. Log the decision **and the reason, including "no"** with the measured numbers: gestures and thresholds were all tuned from logged values.
- **State transitions, not states** (session state, mode, menu open/close, level change); **periodic summaries every 10-30 s** per subsystem (frame pacing, frame time split game vs mod vs runtime, pose ring, GPU lag/busy/VRAM, voice levels, body layer cost); **rate-limit every repeating line** (first 30, 1/10/100/1000, once per 2 s).
- Prove fixes with counters ("Room culling: kept 1000 overlapping runs apart"): a clean test plus a non-zero counter shows the fix did work.
- A `tools/logtail.sh LOG [-n 80] [-t tag,tag] [-g regex]` helper so agents never `cat` a 3 MB log.
- **Where files really are**: with a mod manager's virtual filesystem, files that already existed in the mod folder are written in place and files created at runtime land in an `overwrite` folder. Check both, confirm by modified time. We later moved all outputs to a dedicated mod folder to keep overwrite clean.
- Third-party diagnostics are free: MC Command Center's `mc_lastexception.html` captures every script exception. Find the equivalent for your game and copy it with every test round.

### 12.3 Marks (one button, screenshot + log marker)

- One cheap input (short click of a thumbstick, fires on release if held < 500 ms) with haptic buzz. Each press: non-blocking screenshot (both eyes side by side; the menu layer as `_menu.jpg`), JPEG ~0.92, downscaled 2x, 150-250 KB; one log line with a **fixed greppable prefix**: `Screenshot: saved <path> (WxH, left and right eye) | local YYYY-MM-DD HH:MM:SS | <game-state string> | why: <last 5 decision lines>`; flight-recorder dump; snapshot lines of state that is hard to infer later.
- Capture pattern: `request()` sets an atomic; in the per-frame hook the offered texture is copied into a STAGING texture; next frames `Map(D3D11_MAP_FLAG_DO_NOT_WAIT)`, give up after ~2 s, hand to a detached worker thread to JPEG-encode (WIC) and write; never stall the render thread; cap in-flight writes at 2. Reference: `reference/screenshot.cpp`.
- File names `<mod>_YYYY-MM-DD_HH-MM-SS.jpg`, `_2` `_3`... within a second. `resolved.txt` lists fixed shots; at next start the mod deletes only those (validate: prefix, `.jpg`, no separators or `..`).
- A slicer produces `mark_log_context.txt`: for each mark a header with the marker line, then ~7 s before through a few seconds after of verbatim log lines (windows may overlap). The AI reads this **first**, then the matching JPEG, then the trace dump, and opens the full log only to follow a lead.
- Port checklist is at the end of `MARK-HANDOFF.md`.

### 12.4 Flight recorder and special probes

- **Ring buffer** of every log line (muted ones too), 8 MB or `ring_seconds + 5` old; dumped as `sims4vr_trace_N.log` on every mark, a menu button, or a script `dump: reason` (rate limited to 1 per 3 s). The main log stays 10-40 KB a minute while the dump has the full-rate last 20 s.
- **`why:` lines**: one per decision with inputs (`stairs: on=0 reason=side 0.27>0.25 s=3.1/4.2 level 1->0 ...`); the last 5 are attached to every mark.
- **Frame time split** (`framecost.cpp`): per picture, game update before drawing / other views (shadows, mirrors) / main view / after last draw / Present with VR work and its wait, one line per 10 s at rest and while turning. Splits **game time from your own overhead** every time.
- **GPU**: a `D3D11_QUERY_TIMESTAMP_DISJOINT` + two `TIMESTAMP` queries around each of your own passes, read later with `GetData(..., DONOTFLUSH)`, dropped if `Disjoint`. GPU busy %, video-encoder %, VRAM vs budget via DXGI/Windows counters. (Do NOT fence-wait inside the frame for diagnostics.)
- **Hitch catcher** (Windows): a watchdog thread; when the picture thread exceeds 60 ms between Presents it suspends the thread every 5 ms (max 10 samples per stall), records IP + return addresses from a stack scan, and logs `game+0xrva` stacks. It found 71 of 76 stalls inside the GPU driver (a D3D call waiting on the GPU), which **ruled out simulation and script code**. No allocation or lock while the sampled thread is suspended; 300 lines/session cap.
- **Benchmark** (`benchmark.cpp`): countdown, 5 s still, three turns each way, 5 s still, one result line (pictures/s, p50/p95/p99 game ms, GPU busy, missed refreshes); run paused (render only) and at speed 1 (render + sim) to separate render from simulation.
- **Pass timeline** across the engine's own passes was still being built at handoff.
- **Per-hook/per-wrapper calls-per-second counters** (Cyberpunk VR port finding): the biggest wins were hot-path calls found by counting. Ours: a script wrapper at ~1M calls/min; a thread pile-up in a resource lookup (see Pitfalls); a settings read that opened two files every 0.2 s through the mod manager.

### 12.5 Crash recording

- Vectored exception handler first in line, fatal codes only (access violation, heap corruption `0xC0000374`, illegal instruction, stack overflow), returns `EXCEPTION_CONTINUE_SEARCH`, caps at 8 events and 2 dumps. Crash-safe writing: no heap, no locks, stack buffers + `WriteFile`.
- Text file: time, code, **`module+offset`** (stable across launches), registers, 128 bytes around every register that points at readable memory (as hex and floats), unwound stack plus a raw scan of code addresses on the stack, **"last mod activity"** (each hook stamps time and thread id: "camera copy hook 3 ms ago (thread 32100)" says instantly whether the mod was involved), minidump, a **sentinel** line at startup (`session started; no exception recorded yet`; if the game died and the file still says that, the process was fail-fast killed).
- On launch rename a recorded crash to `_prev` (players relaunch before reporting). Script side: Python `faulthandler` into a fatal log. Keep the linker `.map` file for every build to name functions inside your own DLL. WER LocalDumps (registry) or ProcDump catch fail-fast crashes your recorder cannot see.
- Real example: a dump showed two worker threads inside the same game culling function at once; serialising that function in the mod fixed it, and a counter line proved the race fires thousands of times per test.

### 12.6 Order to build observability in a new mod

1. Logger (ms stamps, tags, flush, banner, rotation). 2. Frame pacing + slow-frame split (game vs yours vs runtime). 3. Crash recorder. 4. Marks + marker line + game-state string. 5. Slicer script. 6. Periodic per-subsystem lines as each is debugged. 7. Flight recorder + dump on mark. 8. GPU timestamps, busy %, hitch catcher. 9. Log collector + process check. 10. Thread roles.

---

## 13. Development process and tooling

### 13.1 Roles

| Role | Does | Does not |
|---|---|---|
| Coordinator | talks to the player, routes work, relays, updates the Linear board | write code |
| Feature thread (one per feature) | researches, changes source on its own branch, reports `Changed / Interfaces / Issues / Next` | build or install |
| Build thread (only one) | claims the next version, builds, packages | install |
| Install thread | checks the game process, copies logs, installs, reports | build |
| Analysis | any thread reading `logs/test-<ver>` | |

### 13.2 The relay flow (PR -> dev -> build -> install -> test)

1. Player reports what they saw. Coordinator forwards to the matching feature thread (one thread per feature; follow-ups go to the existing thread).
2. Feature thread works on its own branch named after its Linear issue (e.g. `gla-21-cap-lead`), commits as it goes, pushes, and opens a PR into **`dev`**. **Threads may merge their PRs into `dev` without asking** while actively developing; `main` stays clean.
3. When code is ready the coordinator **immediately** messages the build thread (the relay rule; nobody waits for the player to ask).
4. Build thread builds from `dev` with one script (`tools/release.sh --thread NAME`), never installs. The report lists changes from other threads that got merged.
5. When the build is done, the coordinator immediately messages the install thread.
6. Install thread **copies the previous run's logs first**, checks the process, installs only when the game is closed, verifies sizes/hashes, reports.
7. Player tests in the headset, presses marks, describes the result. Only the player's in-game confirmation moves an issue to **Done**.
8. `main` only receives builds the user confirmed in game (merge `dev` -> `main`), tagged `v0.13.NNN`, with a GitHub release and plain-language changelog. Never commit release binaries, logs or secrets (API keys stay local). Feature threads in the cloud can only push `claude/*` branches (session restriction), so the pattern was PRs from those branches into `dev`.
9. After a test session: ask follow-up questions about **every In Review card** the user did not clearly pass/fail, and anything explained vaguely; state clearly what is next.

### 13.3 Rules that kept it manageable (copy these)

- **One change per build, one build per test.** Batches made it impossible to tell what broke.
- **Ship builds that start in the mode under test.**
- **Never install into the player's game folder from the cloud**; the player (or install thread via approved folders) puts it in the mod folder and activates it.
- **Game closed protocol**: when the player says "game is closed", that stays true until they say they are back; install every new build immediately; but the install thread **always checks the process** (last log timestamp advancing, or `tasklist`), because the player sometimes relaunches without saying so.
- **Idle threads do nothing**: no polling, no watchers, no self-scheduled check-ins unless asked (token cost).
- **Terse reports**: Changed / Interfaces / Issues / Next. Ask for diffs, not full-file rewrites. Handoff summary + one row in `docs/STATE.md` when done; new work goes to a **new thread** rather than extending a long one.
- **One thread per feature**; route follow-ups to the existing thread; always link threads mentioned.
- **Only one thread edits a file area** (`reference/CODE-MAP.md`): a table of area -> files -> owner; changes to the shared state (`vr.h`, part order, `CMakeLists.txt`) go in their own small commit with no feature code.
- **Linear board is the single list** of ideas, to-dos and bugs (team GLA): one issue per test/feature/fix, status Backlog/Todo/In Progress/In Review (= installed, untested)/Done (= confirmed by the player in game), labels per mod + Bug/Feature/Improvement, an `Idea` label for backlog ideas. Issue ids appear in code comments and settings (GLA-21, GLA-118, GLA-22).
- **Version numbers** are shared: next build = highest of `release/` dirs and git tags + 1 under a file lock with `mkdir` as the claim.

### 13.4 Build system

- Cross-compile on Linux with MinGW-w64 (posix variant; the Win32 thread variant lacks `std::mutex`/`std::thread`) + CMake; CMake fetches OpenXR headers/loader, MinHook, Dear ImGui. `tools/setup-toolchain.sh` restores the toolchain (cached tarballs, ~5 s) in a fresh container. The script mod needs Python 3.7 to compile `.pyc` (the game's version); python.org and GitHub tarballs were blocked, `git clone --depth 1 -b v3.7.17 https://github.com/python/cpython` worked.
- `tools/release.sh` (`reference/release.sh`): syntax-check all Python against the 3.7 grammar, claim a version, build, write version + commit into the DLL and script (the log's first line says `sims4vr v0.13.234 (commit a1b2c3, thread X)`), package `release/vX/` with the linker map, tag. Refuses uncommitted changes in source paths. `--dry-run`, `--no-dll`, `--public` (developer-options row default off), `--allow-dirty` (version line says `+dirty`). Run it with `bash` (the shared mount is noexec).
- **The shared project folder is not a git repo you can trust**: our drive copy's `.git` got corrupted; all commits come from fresh clones of GitHub. Large shared storage also hit a 50,000-file cap (screenshots, trace dumps, 287 full builds at 1.7 GB): cap trace dumps, gzip logs, archive old builds, delete resolved screenshots.
- **Public release hygiene**: whitelist what goes to GitHub (code, build tools, default ini, README, LICENSE, `.gitignore`; no `re/`, `docs/`, `release/`); decompiled game code stays private.

### 13.5 Scripted test commands

- Cheat-console commands registered by the script mod: `vr.start`, `vr.recenter`, `vr.mode`, `vr.scale`, `vr.status`, `vr.findcamera` (camera struct discovery, section 3.3). They exist for development; the **player should never need them** because builds start in the right mode.
- **Developer probe** (section 11) and **benchmark** (section 12.4) are the two scripted-test tools that matter most.
- **Benchmark discipline**: run a baseline first (a busy scene for 5 minutes on the current build) and write the numbers down; every later change is compared with them.
- **Per-effect on/off switches in the debug menu** (live toggles, not restarts where possible) are the cheapest A/B test in a headset: "Test: draw the scene twice (log)", "Depth eye test view 1/2/3/4", `gpu_wait`, `cap_lead`, `ssao_off`. Where a setting needs a restart, say so in the row.

### 13.6 Standalone mods

- Keep separate concerns in **separate DLLs**: each with its own ini, submenu in the VR debug menu, exe-stamp gate, and an export interface other mods can call via `GetModuleHandle` + `GetProcAddress` (`esc_quiet`, `esc_set_elevation`, `esc_set_occlusion`, `esc_get/esc_set`). They work with or without the VR mod. A rule that paid off: **the VR mod never ships another mod's feature and never changes another author's mod**; it adds rows when the other mod is loaded.
- Hook ownership table between mods (who hooks which function) is documented per mod; two detours on one address crash.

### 13.7 Script hooks

`reference/SCRIPT-HOOKS.md`: never assign over a game Python function from a script module. `hooks.hook(tag, owner, name, wrapper, first_person_only=..., order=...)` builds one chain per game function, logs each wrapped function at start with its chain, isolates wrapper errors (the game's function still runs), supports `[hooks] disable=` in the ini, and doubles as a checklist of game functions to diff after an update. It replaced 12 modules each wrapping `InteractionQueue.append` etc. themselves.

---

## 14. Lessons learned and pitfalls (the bugs, and why)

Each entry: symptom -> cause -> what to do. Evidence level in brackets.

### 14.1 Loading and platform

1. **Script mod silently didn't load** -> the game's embedded Python 2025 build has **no `_ctypes`**, so `import ctypes` raised and the loader swallowed it -> export `PyInit_<name>` from the DLL and load it with `ExtensionFileLoader`; make the Python loader log its own failures [proven].
2. **Log files not where expected** -> mod manager (MO2) redirects runtime-created files into `overwrite/`; files that already existed in the mod folder are written in place [proven]. Pre-create empty log files in the package, or put outputs in a dedicated folder.
3. **`near`/`far`/`close` as variable names** don't compile on Windows (macros in `windows.h`) [proven].
4. **MinHook**: `MH_Initialize` may already have been called by another module; accept `MH_ERROR_ALREADY_INITIALIZED`.
5. **Mount noexec** on the shared project folder: run scripts with `bash script.sh`.

### 14.2 Stereo and timing

6. **Double vision / ghosting in alternate-eye mode** -> the two eyes come from different game frames; the whole `[stereo]` bundle (paired eyes, paired hands, turn reprojection, align eyes, body layer) hides it. Do not expect to fix moving objects in that mode [proven].
7. **Pose in the layer != pose drawn** -> frames drawn from an older request submitted with this frame's located pose [measured in another mod; audited here via the pose ring].
8. **Turn jitter when the game fps drops below the headset refresh** -> turning advanced on the PC clock; use the **display clock** and a headset-frame-clock thread [proven].
9. **Walking sideways stutter** -> same cause, for translation (`walk_display_clock`).
10. **Two real passes presented twice** -> the engine presents inside its scene-render function; second pass waited a full headset refresh [measured].
11. **Depth-reprojected second eye never looked right** at edges, glass, alpha hair, near hands, characters: iterative warps converge to the farthest fixed point; forward ray march finds first surface but fill choice produced ghosts; estimated 12 builds; verdict dead end [proven by the user's tests]. If you retry, budget it as research, not a feature.
12. **Depth copy goes stale** -> the copy is recorded in the UI's deferred command list once per Present; two UI frames before a Present leave the second with no copy.
13. **Near plane read after the camera copy is the live camera's, not the drawn one**; store the near/far used when you wrote the camera (`Rendered::nearZ/farZ`).
14. **Everything that assumed one camera per frame** (pick, listener, near-plane sensor with ONE depth slot, UI compositing) breaks in two-view modes. List them before building.

### 14.3 Threading and crashes

15. **Game froze a few frames into body mode** -> `std::mutex` is not re-entrant; `checkHeld` ran inside `applyEye` (pose mutex held) and called `xrToWorld`, which locked it again. Rule: code under the pose lock never calls functions that take it; use a `...Held` variant [proven].
16. **Crash: two worker threads in the same culling function** -> serialise that function from the mod; keep a counter line proving the race fires [proven].
17. **Hang on process exit** -> destroy the XR session before teardown.
18. **Performance cliff from one innocent thread** (`modelbox::readResource`): a single lookup slot meant every different key started a new thread that read every package index (252 game + 590 mod packages); a HUD asked for two missing icons ten times a second, each call replaced the other's slot -> hundreds of threads, 0.2 s lookups becoming 7-9 s, game frame stalls of 400-700 ms every 30 s, "not found" lines up to ~1000/min [proven by log growth and cure]. Fix: one worker thread, list packages once, answer all waiting keys in one pass, **cache negative results**. Rule: **every lookup that can miss needs a cache for the miss.**
19. **Hitches inside the GPU driver, not game code** -> a stack-sampling watchdog showed 71 of 76 stalls in a D3D call waiting on the GPU. Don't guess whether script or sim is the culprit; sample.
20. **Perf measure traps**: wall-time CPU numbers are pacing-bound (waits) when a function presents inside; use `QueryThreadCycleTime` for real CPU cost. Python ticks of 0.3-0.9 ms were fine; frame rate followed **simulation load** (sim updates 67-80 ms at 48-64 fps vs 11 ms at 70 fps).
21. **Settings reads through ini files every call** went through the mod manager's virtual filesystem twice per read; cache values in the DLL for a couple of seconds.
22. **`routing.ray_test` waits on the path planner thread**: 23-67 ms stalls. Reuse a recent result while a plan is in progress; move to a self-contained collision scene (section 7).
23. **Phone take-out hitch of 138-276 ms** from a menu build on the game thread -> move to a worker.

### 14.4 Rendering

24. **Mirrors and water lopsided or popping** -> projection patched instead of camera fields; a cull camera narrowed to a union box inherited the eye lens shift (section 6) [proven].
25. **A third of each eye image was invisible** -> symmetric frustum; use the engine's off-centre support (`exact_fov`) [measured].
26. **Shiny surfaces glowing in the dark** -> cube-map term has no light factor; swapping a global probe did nothing since materials bind their own cube [proven by decode]. Patch shaders (section 5.4).
27. **"Nothing changes at night"** -> scaled sky curve channels that only feed the sky picture; the world reads a different cbuffer filled by a different function [proven].
28. **Black lightmap tile after a zeroed light** -> baked lightmaps persist; never scale below a floor (x0.03).
29. **Shadows "ticking"** -> the sky passes a deliberately stepped sun to the shadow code; copy the smooth one in.
30. **Blurry textures at reduced render scale** -> negative mip bias at `PSSetSamplers`, not at `CreateSamplerState` after startup (samplers existed already).
31. **The patched shader was accepted but wrong** (risk): offline checkers (vkd3d + spirv-val + checksum) and a restart-required off switch.
32. **Shaders created before your hook** are missed; log the count of shaders made before/after first Present.
33. **Per-frame MSAA edge colour moved with the background's depth sample 0** in the depth-eye mode giving see-through rims; use nearest depth over all samples + neighbours.

### 14.5 Input and UI

34. **Page Down became numpad 3 and changed game speed** -> extended keys need the E0 flag in synthetic scan codes [proven].
35. **A UI card re-following the player after 1 m** was rejected twice; follow-at-1 m is a banned pattern (user rule).
36. **Cropped game UI pieces** were rejected repeatedly; draw natively, find the layered parts (badges, art atlas) in the decompiled UI.
37. **Game camera zoom out opens the map**: the right stick's up/down sent mouse-wheel zoom in first person; keep camera-affecting inputs out of first person.
38. **Dialogs and modals pausing the game**: keep the game clock running while your VR picker/phone is open by wrapping `GameClock.push_speed` (and pop/remove) in hooks.
39. **Autosave settings on change** (not on close), or a link freeze loses the player's tweaks.

### 14.6 Process

40. **Batching several features per test** made it impossible to tell what broke -> one change per build.
41. **Reading old docs wastes tokens**: an oversized `NEEDS-TESTING.md` (175 KB) was archived and declared unreadable for threads; the live file starts empty and gets rows only for new installs. Keep living docs under ~20 KB and archive the rest.
42. **Memory/state drift**: ten contradictory "Latest installed" lines in the index. Keep one authoritative state file with one row per feature and one line for latest installed.
43. **Version races** between threads (three builds 231/232/233 on each other) -> lock-protected claim in `release.sh`.
44. **Guessing instead of proving** (inferred cause, one build, wrong) was the single most expensive habit. Rule: prove the cause from data, then code.
45. **Don't present a log as proof**; the headset result wins.
46. **Hard-coded container paths in helper scripts** (RE tools use `/tmp/claude-0/...`) break in new containers; make them take arguments.
47. **A user setting that overrides your default** (an old `depth_eye=1` in the player's ini silently disabled FSR for a build) -> log the effective value and the gate's reason for every feature that has a gate.

### 14.7 Comfort and design (all from the player's feedback)

- Snap turn needs a full stick push; smooth turn should be on the display clock; optional body rotation off by default.
- HUD at the same pixel in both eyes; pose of the phone/menus is final once the user sets it (fit the hand to the phone, not the reverse).
- Hand/body collision once launched the player with capsules: keep it off by default or eased.
- Haptics off by default; "no vibration" was an explicit request.
- Avoid gendered wording in outfit UI; use the game's own term.
- Sound: ALWAYS 3D; clarity matters (compressed source files are low-passed by the game).
- Keep the real game speed. Never change the game's clock without being asked.

---

## 15. External repos, mods and docs we reviewed

Verdicts in short. Full text: `reference/mod-frameworks.md`, `reference/more-integrations.md`, `reference/PERF-LINKS.md`, `reference/RESEARCH-VALVE-TOOLS.md`, `reference/dev-tools.md`, `reference/DEPENDENCIES.md`.

### 15.1 VR injection references

| Repo | What it is | Verdict |
|---|---|---|
| `praydog/REFramework` (MIT) | RE Engine VR/mod framework (DX11/DX12, OpenXR) | **Best reference** for OpenXR plumbing, stereo, frame timing; MIT, copy with notice. |
| `praydog/UEVR` (code: all rights reserved; API.h MIT) | Unreal Engine VR injector | Design ideas only; **don't copy**. |
| `elliotttate/vrframework` (MIT) | VR injection architecture guide/scaffold | Reference; the repo itself contains AI-agent reports. |
| xivr (FFXIV) | Dalamud plugin, DX11 VR | Closest single-engine reference we found for DX11 stereo + game-camera override. |
| `convexvr/sims4-vr` (Apache-2.0; repo now 404/private) and `krystal-large/sims4-vr` (fork) | Python mod + DX9 + OpenVR + vorpX. Hooked the same camera-copy function we did. | We took one **fact** (where the camera copy lives), no code. Alternate-eye on DX9 with a SurfaceQueue bridge; pyautogui input; no hands. Credit convexvr in the README. Also showed that writing the projection matrix is fragile (blurry result). |
| `dariulone/cyberpunk-vr-port` (MIT; RED4ext, D3D12) | Cyberpunk VR port | Only ideas transfer. Tips we adopted or listed: per-call counters to find hot paths, never fence-wait per frame for diagnostics, submit the pose the frame was drawn with, rate-limit log spam, drain the D3D debug layer once, diagnostics off by default, hook-collision rule. |
| `mbucchia/VirtualDesktop-OpenXR` (VDXR) | The runtime we ran through; wiki lists its extensions | VDXR offers hand tracking, body/face tracking (face v2 has an audio source); **no passthrough, space warp or foveation extension**; no `XR_KHR_visibility_mask`. |
| `mbucchia/Quad-Views-Foveated`, `fholger/vrperfkit` | Foveation / FSR for DX11 VR | Foveation layer needs four views (too costly); vrperfkit worth a look for DX11 FSR/foveation. |
| ReShade | coexistence | Users run it alongside; **never redistribute its binaries**. |
| OpenXR Toolkit | discontinued | Don't use. |

### 15.2 Libraries

| Library | Use | Licence |
|---|---|---|
| MinHook | hooking (what we use) | BSD-2 |
| SafetyHook (`cursey/safetyhook`) | stronger hooking, mid-function hooks | Boost 1.0 |
| Dear ImGui | HUD/menus into textures (**used**) | MIT (AI-generated contributions banned only for contributions to ImGui itself) |
| FidelityFX FSR1 | upscale + RCAS sharpen (**used**; FSR 2/3 are DX12) | MIT |
| Steam Audio (`ValveSoftware/steam-audio`) | HRTF, occlusion, reflections (**used** in the sound mod) | Apache-2.0 |
| libmysofa (Valve fork) | load SOFA HRTF sets | BSD-3 |
| Jolt Physics | PLANCK-style collision, ragdolls | MIT |
| ozz-animation, TheComet/ik | animation / IK maths | MIT |
| Tracy | frame profiler, zero cost when no viewer | BSD-3 |
| NVAPI VRS | fixed foveated rendering on NVIDIA DX11 | MIT |
| RmlUi + msdfgen | HTML/CSS UI to texture, sharp VR fonts | MIT |
| Silero VAD, sherpa-onnx | jaw on real speech; offline keyword spotting for voice commands | MIT / Apache-2.0 |
| Meta Haptics SDK | designed vibration clips | MIT |
| Ultimate ASI Loader | load DLL at game start | MIT |
| **Avoid** Meta OVRLipSync / Meta XR Audio SDKs | licence limits to Meta-approved hardware and forbids modification | |

Sims-specific script libraries (Lot 51 Core, XML Injector, S4CL) were optional companions only; they must not be bundled.

### 15.3 Valve and talks

- Alex Vlachos, **"Advanced VR Rendering" (GDC 2015)** and **"Advanced VR Rendering Performance" (GDC 2016)**: hidden-area mask, adaptive quality, fixed foveation, dynamic resolution, late latching. Free talks, ideas only.
- `ValveSoftware/the_lab_renderer` (Unity): reference for hidden-area mesh and adaptive quality logic.
- `ValveSoftware/OpenXR-Canonical-Pose-Tool`: compare grip/aim poses across runtimes (explains hand-offset differences).
- Valve has no free tool for DX11 VR compositing; perf ideas come from the talks.

### 15.4 Debugging and profiling tools

Meta Quest Developer Hub / `adb logcat` (the only way to see why the VD app on the headset stopped), OVR Metrics Tool, VD performance overlay, Windows Error Reporting LocalDumps, ProcDump, WinDbg, Tracy, PresentMon / CapFrameX, NVIDIA Nsight Systems / FrameView, GPUView, **RenderDoc** (single-frame draw call capture on DX11), Khronos OpenXR API layers (`api_dump`, validation), JPEXS FFDec (Flash), vkd3d-compiler and spirv-val (shader validation), Ghidra 11.4.2 headless.

### 15.5 Sims-specific community pointers (only useful if you stay on this game)

- Fade/DOF are data: Renderer Fade Tuning and GlobalDofSettings SimData instances; override or edit at runtime.
- Decompilers: BigBadBleuCheese/Motherlode, reyemxela/sims4-decompiler. Community: Lot 51 Discord, TDESC browser, S4CL docs.
- Community stance on AI-written mods is wary (a major compatibility tracker dropped an AI-assisted mod, 2026-10); a script-mod malware scanner (ModGuard) may flag a script mod that loads a native DLL; contact its author before a public release.

---

## 16. Suggested plan for a new game (derived from our order of work)

Order that worked, compressed. Each step is one build and one test.

1. **Recon (days 1-2)**: confirm API (DX11?), PE stamp, mod loader route, where logs land. Stage the exe, decompile with Ghidra, build `classes.tsv` and `strings.tsv`. Find the camera object (script API trick or memory search) and the copy function.
2. **Logger + crash recorder first**, banner, rotation, `bash tools/release.sh`-style one-command build, one install path.
3. **Present hook + OpenXR session + quad mode** (flat screen on a quad in VR). Proves the session, swapchains, headset recenter. Our first headset pass was this, at eye level.
4. **Camera override + alternate-eye stereo** at a modest render scale. Hand the compositor the pose each picture was drawn with from the very start (sequence-tag the pose requests, section 3.6).
5. **Latency pass**: pose ring, frame-clock thread if needed, `cap_lead` / `gpu_wait` A/B, GPU yield. Turn reprojection if stick turning exists.
6. **Link robustness**: bounded waits, watchdog, clean session end, backoff, autosave settings.
7. **Marks and the AI log loop** before any big feature.
8. **Locomotion + free controller + body**, one behaviour at a time, using the engine's skeleton hook.
9. **UI**: separate the UI layer, laser, one native menu; then phone/wrist/pie as needed.
10. **Hands/IK, grab, touch, collision** (probe the navmesh API first).
11. **Polish**: near plane/near-fade, mirrors per eye, shadows, FSR, texture bias, sound (3D + occlusion), shader patches.
12. **Release hygiene**: address table with signatures, patch report, public build switch, GitHub release from confirmed builds only.

Things to **not** do early: depth-reprojected stereo, two-pass rendering, DX9 parity, custom physics beyond capsules, voice features.

---

## 17. Index of files

In `reference/` (copied from the project; originals in `/mnt/project-files/sims4vr/`, `/mnt/project-files/handoffs/`, sound and lighting repos):

| File | What |
|---|---|
| `STEREO-FEASIBILITY.md`, `SINGLE-VIEW-HANDOFF.md` | Every stereo option with numbers; the two-pass probe and depth-eye logs (long, valuable). |
| `PERFORMANCE.md`, `PERF-LINKS.md` | Measured performance, the thread pile-up, Cyberpunk VR tips, pie build cost. |
| `vd-freeze-handoff.md` | Virtual Desktop stalls with full OpenXR code. |
| `vr-mod-logging-handoff.md`, `monitoring-handoff.md`, `MARK-HANDOFF.md`, `screenshot.cpp`, `logtail.sh` | Log/marks/flight recorder/crash/hitch; reference implementation. |
| `EXE-INDEX-README.md`, `mirror_camera.md` | How the exe index is built and used; address table; patch procedure; mirror camera RE. |
| `REFLECTIONS.md` | Mirrors and water. |
| `COLLISION-PLAN.md` | Collision scene plan with probe results. |
| `HAND-RIG.md` | Rig joint names and the hand-tracking mapping. |
| `UI-KIT.md`, `ui-techniques.md` | Native UI kit and Scaleform/SWF techniques. |
| `FLASHLIGHT-PS.md`, `FLASHLIGHT-BEAM.md`, `SHINE-IN-DARK.md`, `CB7-LIGHTCBUFFER.md`, `FOLIAGE-PUSH.md`, `beampatch.cpp/.h`, `foliagepatch.cpp` | Shader RE and the DXBC patchers (copyable patterns). |
| `LIGHTING-DESIGN.md` | Realistic Lighting: every version with what it learned. |
| `SOUND-FEASIBILITY.md`, `SOUND-NEEDS-TESTING.md` | Sound engine and the HRTF journey. |
| `CODE-MAP.md`, `RULES.md`, `SCRIPT-HOOKS.md`, `release.sh` | Ownership table, user rules, hook helper, build script. |
| `mod-frameworks.md`, `more-integrations.md`, `RESEARCH-VALVE-TOOLS.md`, `dev-tools.md`, `DEPENDENCIES.md` | Libraries, mods, Valve tools, profiling tools reviewed. |

Not copied (large, Sims-specific, still in the project): the full exe decompile and indexes (`re/exe/6aa08454`), decompiled game Python (`re/python128`), all UI SWFs (`re/allui`), shader dumps, the source tree (`sims4vr/src`, 200+ files), `docs/STATE.md` (per-feature state, 61 KB), `docs/MENU-PATHS.md` (menu tree), logs under `logs/`, the three GitHub repos.

Key source files to read when porting a pattern (all in `sims4vr/src/`): `d3d11_hook.cpp` (Present hook), `vr_parts/18_stereo.inc` (frame loop, pose ring), `camera.cpp` (camera hook, lead cap), `gpuload.cpp` (GPU wait, timestamps, busy %), `uihook.cpp` (scene/UI targets), `beampatch.cpp` / `foliagepatch.cpp` / `beamlight.cpp` / `foliagepush.cpp` (DXBC patchers + hooks), `armik.cpp` (arm and finger IK), `collide.cpp` and `scriptmod/sims4vr/collide.py`, `addrs.cpp` and `tools/gen_addrs.py`, `framecost.cpp`, `hitch.cpp`, `crashlog.cpp`, `screenshot.cpp`, `log.cpp`.

---

## 18. Known open items at handoff (2026-11-26, game 1.129.39.1030)

- Installed VR 0.13.919 + Lighting 0.9.17 + Sound 0.9.6 + Performance 0.5.0; fixes from the last test (flashlight, camera layout, lock screen, CAS ghost torso) installed and untested.
- Pose ring + late pose (GLA-22), `cap_lead` (GLA-21) and `gpu_wait` (GLA-118) code exists; effect not yet measured in the headset.
- Reverb "very unbalanced" (GLA-9): outdoors dry, level match and smooth room changes being fixed.
- Some filters (GLA-137) may not show on the viewfinder; shutter-dependent Photos feature (GLA-53).
- Sim shaking when moving/turning is **not** respawning; `turn_body_lazy` built but untested.
- Hand tracking mapping was never seen live; tracked hands are "looks only".
- Quest 3 has no eye tracking; VDXR offers no passthrough, space warp, foveation or visibility mask.
- Local git repo on the project drive is corrupt; always work from a fresh clone; release not yet cut; GitHub Actions builds skipped by the user.
