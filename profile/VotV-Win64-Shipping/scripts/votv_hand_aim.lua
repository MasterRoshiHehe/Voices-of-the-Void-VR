-- VOTV VR: aim from the right hand (UEVR Lua). Controls thread, 2026-11-27. Rung 2 of CONTROLS.md section 5.
--
-- Why: every look/use/pick-up/carry ray in the game comes from mainPlayer_C:arm(), which reads the
-- *player camera manager actor's* location and forward vector (docs/GAME-INTERNALS.md section 3). With UEVR's
-- right-controller aim only the direction followed the hand while the ray still started at the head, so the
-- selection landed above and left of where the hand pointed (user 2026-11-27 02:07, stuck at the keypad).
--
-- How: a scene component added to the pawn is driven by the right controller (UEVR UObjectHook motion
-- controller state, permanent). After each world tick (after the camera manager's own update, before the
-- pawn's next tick) the camera manager *actor* is moved to that component's location and rotation. The
-- rendered view comes from the camera cache, not the actor, so the view doesn't move; the game's rays do.
-- UEVR's own aim method stays on Head (plugin setting ctl_aim_method=1), so walking and the HUD follow the head.
--
-- Optional: hand_arms=1 also attaches the game's first-person arms meshes to the controllers.
-- Settings arrive from the controls plugin as "votv_cfg" Lua events (keys hand_*, from scripts\votv_controls.txt;
-- UEVR 1.05 Lua has no file access). Idle until the plugin is seen. Log lines: "[votv-hand]".

local function log(s) pcall(function() uevr.params.functions.log_info("[votv-hand] " .. tostring(s)) end) end

local cfg = { hand_aim = 1, hand_arms = 0, hand_log_s = 2, hand_pre_apply = 0, hand_tick_apply = 0, hand_max_cm = 150, hand_gpcm_hook = 1 }
local active = false

local function parse_cfg(text)
    for k, v in string.gmatch(text, "(hand_[%w_]+)%s*=%s*(%-?[%d%.]+)") do
        local n = tonumber(v)
        if n ~= nil and cfg[k] ~= n then cfg[k] = n; log("setting " .. k .. "=" .. v) end
    end
end

pcall(function()
    uevr.sdk.callbacks.on_lua_event(function(name, data)
        if name == "votv_cfg" then parse_cfg(tostring(data)); active = true
        elseif name == "votv_ctl" then active = true end
    end)
end)

local api = uevr.api
local function find(path)
    local ok, o = pcall(function() return api:find_uobject(path) end)
    return ok and o or nil
end
local function struct(path)
    local c = find(path)
    if c == nil then return nil end
    return StructObject.new(c)
end
local kml = nil
local scene_class = nil
local hit = nil

local function vec(x, y, z) local v = struct("ScriptStruct /Script/CoreUObject.Vector"); v.X = x; v.Y = y; v.Z = z; return v end
local function rot(p, y, r) local v = struct("ScriptStruct /Script/CoreUObject.Rotator"); v.Pitch = p; v.Yaw = y; v.Roll = r; return v end

local state = { pawn = nil, hand = nil, arms_done = false, last_log = 0, t = 0, sets = 0, fails = 0 }

local function attach(comp, hand)
    local s = UEVR_UObjectHook.get_or_add_motion_controller_state(comp)
    if s == nil then return false end
    s:set_hand(hand)
    local ok = pcall(function() s:set_permanent(true) end)
    if not ok then pcall(function() s:set_permanant(true) end) end
    return true
end

local hook_gpcm   -- defined below (needs dist and the camera manager helpers)

local function setup(pawn)
    state.pawn, state.hand, state.arms_done = pawn, nil, false
    -- static library functions are called on the class default object, not the class
    if kml == nil then
        local c = find("Class /Script/Engine.KismetMathLibrary")
        if c ~= nil then pcall(function() kml = c:get_class_default_object() end) end
        kml = kml or find("KismetMathLibrary /Script/Engine.Default__KismetMathLibrary")
    end
    scene_class = scene_class or find("Class /Script/Engine.SceneComponent")
    hit = hit or struct("ScriptStruct /Script/Engine.HitResult")
    if kml == nil or scene_class == nil then log("setup: classes not found"); return end
    local t = kml:MakeTransform(vec(0, 0, 0), rot(0, 0, 0), vec(1, 1, 1))
    local comp = pawn:AddComponentByClass(scene_class, true, t, false)
    if comp == nil then log("setup: AddComponentByClass returned nil"); return end
    if not attach(comp, 1) then log("setup: motion controller state failed"); return end
    state.hand = comp
    hook_gpcm()
    log("hand component attached to the right controller on " .. pawn:get_full_name())
end

local function attach_arms(pawn)
    state.arms_done = true
    local ok1 = pcall(function() return attach(pawn.arms, 1) end)
    local ok2 = pcall(function() return attach(pawn.arms_off, 0) end)
    log("arms attached: right " .. tostring(ok1) .. ", left " .. tostring(ok2))
end

local function dist(a, b) local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z; return math.sqrt(dx * dx + dy * dy + dz * dz) end

-- Hand ray via the game's own first call: mainPlayer_C:arm() starts with GameplayStatics.GetPlayerCameraManager,
-- then reads that actor's location/rotation/forward (pak call order, docs/GAME-INTERNALS.md section 3).
-- GetPlayerCameraManager is a *native* UFunction, so UEVR's hook_ptr intercepts Blueprint calls to it without
-- touching function flags (forcing FUNC_Native on the Blueprint arm() froze the game on load, run 02:58).
-- Pre-hook: move the camera manager actor to the right hand, so the arm() call that follows uses the hand.
-- The view/HUD come from the camera cache, rewritten by the camera update after the pawn ticks, so they stay on
-- the head (UEVR aim method Head). Other Blueprint users of the camera manager (gravity gun trace, hotbar
-- drop placement) follow the hand too, which is wanted. Counts are logged with the periodic line.
local hook_stats = { calls = 0, moved = 0, max_off = 0 }
local function alive(o) return o ~= nil and UEVR_UObjectHook.exists(o) end
local function move_pcm_to_hand()
    if state.hand == nil or state.untracked or state.pawn == nil then return end
    -- The hook can fire during a level change or respawn before the tick notices the new pawn: never touch a
    -- component or pawn that no longer exists, or a pawn that isn't the current one.
    if not alive(state.hand) or not alive(state.pawn) or api:get_local_pawn(0) ~= state.pawn then return end
    local pc = api:get_player_controller(0)
    local pcm = pc and pc.PlayerCameraManager
    if pcm == nil then return end
    local loc = state.hand:K2_GetComponentLocation()
    local off = dist(pcm:K2_GetActorLocation(), loc)
    hook_stats.calls = hook_stats.calls + 1
    if off > 0.5 then hook_stats.moved = hook_stats.moved + 1 end
    if off > hook_stats.max_off then hook_stats.max_off = off end
    if off > 0.5 then pcm:K2_SetActorLocationAndRotation(loc, state.hand:K2_GetComponentRotation(), false, hit, false) end
end
local gpcm_hooked = false
hook_gpcm = function()
    if gpcm_hooked then return end
    gpcm_hooked = true
    local ok, err = pcall(function()
        local f = find("Function /Script/Engine.GameplayStatics.GetPlayerCameraManager")
        if f == nil then error("GameplayStatics.GetPlayerCameraManager not found") end
        f:hook_ptr(function(fn, obj, locals, result)
            if active and cfg.hand_aim ~= 0 and cfg.hand_gpcm_hook ~= 0 then pcall(move_pcm_to_hand) end
            return true
        end, nil)
    end)
    log(ok and "hooked GameplayStatics.GetPlayerCameraManager (pre: camera manager to the hand)" or ("GetPlayerCameraManager hook failed: " .. tostring(err)))
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    if not active or cfg.hand_aim == 0 then return end
    local ok, err = pcall(function()
        local pawn = api:get_local_pawn(0)
        if pawn == nil then return end
        local pn = pawn:get_full_name()
        if not pn:find("mainPlayer") then return end
        if pawn ~= state.pawn or state.hand == nil or not UEVR_UObjectHook.exists(state.hand) then setup(pawn) end
        if state.hand == nil then return end
        if cfg.hand_arms ~= 0 and not state.arms_done then attach_arms(pawn) end
        local pc = api:get_player_controller(0)
        local pcm = pc and pc.PlayerCameraManager
        if pcm == nil then return end
        local loc = state.hand:K2_GetComponentLocation()
        local r = state.hand:K2_GetComponentRotation()
        -- Controller not tracked yet (self-check 02:29: hand reported 403 cm from the head with zero rotation):
        -- leave the game's own head ray alone.
        local head = pawn.Camera:K2_GetComponentLocation()
        if dist(loc, head) > (cfg.hand_max_cm or 150) then
            if not state.untracked then state.untracked = true; log("hand too far from head (untracked?): using the head ray") end
            return
        end
        if state.untracked then state.untracked = false; log("hand tracked again: ray from the hand") end
        -- Per-frame move off by default (run 02:45: turning the camera manager with the hand swung the HUD);
        -- the arm() pre-hook moves it only for the game's own ray, and the camera update puts it back before rendering.
        if cfg.hand_tick_apply ~= 0 then pcm:K2_SetActorLocationAndRotation(loc, r, false, hit, false) end
        state.sets = state.sets + 1
        state.t = state.t + delta
        if state.t - state.last_log >= cfg.hand_log_s then
            state.last_log = state.t
            local head = pawn.Camera:K2_GetComponentLocation()
            local now = pcm:K2_GetActorLocation()
            log(string.format("hand-head %.0f cm, pcm-hand %.1f cm, hand rot p%.0f y%.0f, sets %d; GetPlayerCameraManager calls %d, camera manager moved to the hand %d times (max %.0f cm away)",
                dist(loc, head), dist(now, loc), r.Pitch, r.Yaw, state.sets, hook_stats.calls, hook_stats.moved, hook_stats.max_off))
            hook_stats.calls, hook_stats.moved, hook_stats.max_off = 0, 0, 0
        end
    end)
    if not ok then
        state.fails = state.fails + 1
        if state.fails <= 5 then log("tick error " .. tostring(err)) end
    end
end)

-- Also apply at the start of the next frame (in case anything resets the camera manager actor between frames),
-- and log where the game's own look ray actually went (user 02:33: "I don't highlight things with my hand
-- anymore, that is done with my view"). Angles are between directions from the hand (or the head) and the
-- game's look hit point (pawn.hitResult): small "from hand" = the game aims with the hand.
local function angle(a, b)
    local la = math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z); local lb = math.sqrt(b.X * b.X + b.Y * b.Y + b.Z * b.Z)
    if la < 1e-6 or lb < 1e-6 then return -1 end
    local d = (a.X * b.X + a.Y * b.Y + a.Z * b.Z) / (la * lb)
    return math.deg(math.acos(math.max(-1, math.min(1, d))))
end
local function sub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end

local pre_t = 0
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if not active or cfg.hand_aim == 0 or state.hand == nil or state.untracked then return end
    pcall(function()
        local pcm = api:get_player_controller(0).PlayerCameraManager
        local loc = state.hand:K2_GetComponentLocation()
        local r = state.hand:K2_GetComponentRotation()
        local moved = dist(pcm:K2_GetActorLocation(), loc)
        if cfg.hand_pre_apply ~= 0 then pcm:K2_SetActorLocationAndRotation(loc, r, false, hit, false) end
        pre_t = pre_t + delta
        if pre_t < cfg.hand_log_s then return end
        pre_t = 0
        local pawn = state.pawn
        local hf = state.hand:GetForwardVector()
        local pf = pcm:GetActorForwardVector()
        local head = pawn.Camera:K2_GetComponentLocation()
        local vf = pawn.Camera:GetForwardVector()
        local hr = nil
        pcall(function() hr = pawn.hitResult end)
        local hp, ts = nil, nil
        pcall(function() hp = hr.bBlockingHit and hr.ImpactPoint or hr.TraceEnd; ts = hr.TraceStart end)
        if ts == nil then hp = nil end
        local msg = string.format("pre-tick: pcm moved %.1f cm since last set, pcm-vs-hand dir %.1f deg, view-vs-hand dir %.1f deg",
            moved, angle(pf, hf), angle(vf, hf))
        -- The look target the game picked, by its location (FHitResult fields don't read from Lua here).
        local la = nil
        pcall(function() la = pawn.lookAtActor end)
        if la ~= nil then
            local ok2, alo = pcall(function() return la:K2_GetActorLocation() end)
            if ok2 and alo ~= nil then
                msg = msg .. string.format(" | look target %s: off hand ray %.1f deg, off head view %.1f deg",
                    la:get_fname():to_string(), angle(sub(alo, loc), hf), angle(sub(alo, head), vf))
            end
        end
        if hp ~= nil then
            msg = msg .. string.format(" | game hit %s: from hand %.1f deg, from head %.1f deg; game trace starts %.0f cm from hand, %.0f cm from head",
                tostring(hr.bBlockingHit), angle(sub(hp, loc), hf), angle(sub(hp, head), vf), dist(ts, loc), dist(ts, head))
        end
        log(msg)
    end)
end)

log("loaded (idle until the controls plugin is seen)")
