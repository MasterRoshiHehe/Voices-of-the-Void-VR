-- VOTV VR: controls probe (UEVR Lua). Controls thread, 2026-11-27.
--
-- Shows whether the game actually *did* what the controller plugin (votv_controls.dll) sent: every
-- 50 ms it reads the player pawn's own input/result variables (docs/GAME-INTERNALS.md sections 4, 5, 8)
-- and logs a "[votv-probe]" line to UEVR's log.txt whenever one changes. Read-only: it never writes to
-- the game. The plugin's own "[votv-ctl]" lines (keys sent) sit next to these in the same log.
--
-- Watched (pawn mainPlayer_C): input_use, input_E, input_fire, input_LMB, input_rotate, input_drop,
-- input_crouch, grabbing_actor, lookAtActor, flashlight (light_R visible), and moving (speed > 50 cm/s).

local function log(s)
    pcall(function() uevr.params.functions.log_info("[votv-probe] " .. tostring(s)) end)
end

local function name_of(o)
    if o == nil then return "none" end
    local ok, n = pcall(function() return o:get_fname():to_string() end)
    if ok and n then return n end
    ok, n = pcall(function() return o:get_full_name() end)
    return ok and n or "?"
end

local BOOLS = { "input_use", "input_E", "input_fire", "input_LMB", "input_rotate", "input_drop", "input_crouch" }
local last = {}
local acc = 0
local pawn_name = nil
local warned = {}

local function read(pawn, key)
    local ok, v = pcall(function() return pawn[key] end)
    if not ok then
        if not warned[key] then warned[key] = true; log("can't read " .. key .. ": " .. tostring(v)) end
        return nil
    end
    return v
end

local function sample(pawn)
    local s = {}
    for _, k in ipairs(BOOLS) do
        local v = read(pawn, k)
        if v ~= nil then s[k] = tostring(v) end
    end
    s.grabbing_actor = name_of(read(pawn, "grabbing_actor"))
    s.lookAtActor = name_of(read(pawn, "lookAtActor"))
    local light = read(pawn, "light_R")
    if light ~= nil then
        local ok, vis = pcall(function() return light:IsVisible() end)
        if ok then s.flashlight = tostring(vis) end
    end
    local ok, speed = pcall(function() local v = pawn:GetVelocity(); return math.sqrt(v.X * v.X + v.Y * v.Y) end)
    if ok and speed then s.moving = tostring(speed > 50) end
    return s
end

-- Stays idle (no reads, no log lines) until the controls plugin sends its first event, so runs without the
-- plugin (other threads' tests) are unchanged.
local active = false
pcall(function()
    uevr.sdk.callbacks.on_lua_event(function(event_name, event_data)
        if event_name == "votv_ctl" then
            if not active then active = true; log("active (plugin event: " .. tostring(event_data) .. ")") end
        end
    end)
end)

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if not active then return end
    acc = acc + delta
    if acc < 0.05 then return end
    acc = 0
    local ok, err = pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        if pawn == nil then return end
        local pn = name_of(pawn)
        if pn ~= pawn_name then pawn_name = pn; last = {}; log("pawn " .. pn) end
        if not pn:find("mainPlayer") then return end
        local s = sample(pawn)
        local changes = {}
        for k, v in pairs(s) do
            if last[k] ~= v then changes[#changes + 1] = k .. "=" .. v end
        end
        if #changes > 0 then table.sort(changes); log(table.concat(changes, " ")) end
        last = s
    end)
    if not ok then log("tick error " .. tostring(err)) end
end)

log("loaded (idle until the controls plugin is seen)")
