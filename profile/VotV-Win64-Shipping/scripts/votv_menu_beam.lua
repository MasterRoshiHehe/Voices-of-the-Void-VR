-- VOTV VR: experimental laser beam mesh on the right controller in the flat menu (UEVR Lua). Menu-laser thread,
-- 2026-11-27. OFF by default (menu_beam = 0 in scripts\votv\settings.lua) and expected to look wrong:
--
-- Reasoning (not yet seen in the headset): in UEVR's 2D screen mode the game's mono world render is shown on a
-- flat quad. A mesh spawned into the world is drawn by the game camera into that picture, so it would show as
-- a stick somewhere inside the flat image (seen from the menu camera), not as a beam from the real hand.
-- A real beam needs drawing in UEVR's VR overlay, which UEVR 1.05's Lua can't do. Also, the default launch is
-- -LateInject (menus flat in Virtual Desktop, VD's own laser), so UEVR isn't even loaded in the menus then.
-- This file exists so the idea can be checked once in the headset (menu_beam = 1, live) and then dropped.
--
-- Live settings (scripts\votv\settings.lua, re-read every second):
--   menu_beam (0)          1 = spawn the beam in the flat menu worlds (main menu, preLoad); never in gameplay
--   menu_beam_len_cm (200) beam length (the default 2D screen model puts the screen 2 m away)
--   menu_beam_thick_cm (0.6) beam diameter
-- Every engine call is inside pcall; state transitions are logged with the prefix "[votv-beam]".

local api = uevr.api

local function log(s)
    pcall(function() uevr.params.functions.log_info("[votv-beam] " .. tostring(s)) end)
end

local script_dir = nil
pcall(function() script_dir = uevr.params.functions.get_persistent_dir() .. "\\scripts\\" end)
if script_dir ~= nil then pcall(function() package.path = script_dir .. "?.lua;" .. package.path end) end

local settings = {}
local function load_settings()
    local ok, t = pcall(function() package.loaded["votv/settings"] = nil; return require("votv/settings") end)
    settings = (ok and type(t) == "table") and t or {}
end
local function num(name, default) local v = tonumber(settings[name]); if v == nil then return default end; return v end

local function find(path) local ok, o = pcall(function() return api:find_uobject(path) end); return ok and o or nil end
local function struct(path) local c = find(path); return c and StructObject.new(c) or nil end
local function vec(x, y, z) local v = struct("ScriptStruct /Script/CoreUObject.Vector"); v.X = x; v.Y = y; v.Z = z; return v end
local function rot(p, y, r) local v = struct("ScriptStruct /Script/CoreUObject.Rotator"); v.Pitch = p; v.Yaw = y; v.Roll = r; return v end

local st = { comp = nil, owner = nil, state = "off", t = 0, len = nil, thick = nil }
local function set_state(s, why) if s ~= st.state then st.state = s; log(s .. (why and (" (" .. why .. ")") or "")) end end

local function flat_world()
    local ok, n = pcall(function() return api:get_engine().GameViewport.World:get_full_name():lower() end)
    if not ok or type(n) ~= "string" then return false end
    return n:find("/game/menu%.menu") ~= nil or n:find("/game/maps/preload") ~= nil
end

local function remove()
    if st.comp ~= nil then
        pcall(function() if UEVR_UObjectHook.exists(st.comp) then st.comp:K2_DestroyComponent(st.comp) end end)
    end
    st.comp, st.owner, st.len, st.thick = nil, nil, nil, nil
end

local function apply_scale()
    local len, thick = num("menu_beam_len_cm", 200), num("menu_beam_thick_cm", 0.6)
    if len == st.len and thick == st.thick then return end
    st.len, st.thick = len, thick
    -- /Engine/BasicShapes/Cylinder: 100 cm tall along local Z, 100 cm diameter, pivot at its centre.
    pcall(function() st.comp:SetWorldScale3D(vec(thick / 100, thick / 100, len / 100)) end)
    local s = UEVR_UObjectHook.get_motion_controller_state(st.comp)
    if s ~= nil then pcall(function() s:set_location_offset(Vector3f.new(len / 2, 0, 0)) end) end
    log(string.format("beam length %.0f cm, diameter %.1f cm", len, thick))
end

local function spawn()
    local pc = api:get_player_controller(0)
    if pc == nil then set_state("waiting", "no player controller"); return end
    local mesh = find("StaticMesh /Engine/BasicShapes/Cylinder.Cylinder")
    local cls = find("Class /Script/Engine.StaticMeshComponent")
    local kml_c = find("Class /Script/Engine.KismetMathLibrary")
    if mesh == nil or cls == nil or kml_c == nil then set_state("failed", "Cylinder mesh or classes not loaded"); return end
    local kml = kml_c:get_class_default_object()
    local comp = pc:AddComponentByClass(cls, true, kml:MakeTransform(vec(0, 0, 0), rot(0, 0, 0), vec(1, 1, 1)), false)
    if comp == nil then set_state("failed", "AddComponentByClass returned nil"); return end
    comp:SetStaticMesh(mesh)
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    local s = UEVR_UObjectHook.get_or_add_motion_controller_state(comp)
    if s ~= nil then
        s:set_hand(1)
        if not pcall(function() s:set_permanent(true) end) then pcall(function() s:set_permanant(true) end) end
        -- cylinder axis (Z) along the controller's forward (X): pitch it 90 degrees
        if not pcall(function() s:set_rotation_offset(Vector3f.new(math.rad(-90), 0, 0)) end) then
            log("set_rotation_offset failed; beam axis may be wrong")
        end
    end
    st.comp, st.owner = comp, pc
    apply_scale()
    set_state("on", "attached to the right controller via " .. pc:get_full_name())
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local ok, err = pcall(function()
        st.t = st.t + (delta or 0)
        if st.t >= 1 then st.t = 0; load_settings() end
        local want = num("menu_beam", 0) ~= 0 and flat_world()
        if st.comp ~= nil and not UEVR_UObjectHook.exists(st.comp) then st.comp = nil; set_state("off", "component gone (level change)") end
        if not want then
            if st.comp ~= nil then remove() end
            set_state("off", num("menu_beam", 0) == 0 and "menu_beam=0" or "not a flat menu world")
            return
        end
        if st.comp == nil then
            if st.state ~= "failed" then spawn() end
        else
            apply_scale()
        end
    end)
    if not ok then set_state("failed", tostring(err)); remove() end
end)

log("loaded (menu_beam default 0)")
