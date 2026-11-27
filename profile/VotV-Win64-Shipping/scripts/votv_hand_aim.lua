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

local cfg = { hand_aim = 1, hand_arms = 0, hand_log_s = 2 }
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
    log("hand component attached to the right controller on " .. pawn:get_full_name())
end

local function attach_arms(pawn)
    state.arms_done = true
    local ok1 = pcall(function() return attach(pawn.arms, 1) end)
    local ok2 = pcall(function() return attach(pawn.arms_off, 0) end)
    log("arms attached: right " .. tostring(ok1) .. ", left " .. tostring(ok2))
end

local function dist(a, b) local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z; return math.sqrt(dx * dx + dy * dy + dz * dz) end

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
        pcm:K2_SetActorLocationAndRotation(loc, r, false, hit, false)
        state.sets = state.sets + 1
        state.t = state.t + delta
        if state.t - state.last_log >= cfg.hand_log_s then
            state.last_log = state.t
            local head = pawn.Camera:K2_GetComponentLocation()
            local now = pcm:K2_GetActorLocation()
            log(string.format("hand-head %.0f cm, pcm-hand %.1f cm, hand rot p%.0f y%.0f, sets %d",
                dist(loc, head), dist(now, loc), r.Pitch, r.Yaw, state.sets))
        end
    end)
    if not ok then
        state.fails = state.fails + 1
        if state.fails <= 5 then log("tick error " .. tostring(err)) end
    end
end)

-- Check that the move survives until the pawn's tick: compare the camera manager actor with the hand at the
-- start of the next frame (logged with the same cadence as above).
local pre_t = 0
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if not active or cfg.hand_aim == 0 or state.hand == nil then return end
    pre_t = pre_t + delta
    if pre_t < cfg.hand_log_s then return end
    pre_t = 0
    pcall(function()
        local pcm = api:get_player_controller(0).PlayerCameraManager
        log(string.format("pre-tick pcm-hand %.1f cm", dist(pcm:K2_GetActorLocation(), state.hand:K2_GetComponentLocation())))
    end)
end)

log("loaded (idle until the controls plugin is seen)")
