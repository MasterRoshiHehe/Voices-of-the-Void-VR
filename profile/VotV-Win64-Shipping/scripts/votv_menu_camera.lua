-- VOTV VR: main-menu camera probe and aspect-ratio fix (UEVR Lua, 2026-11-27).
--
-- Why: the main menu shows black borders and is cross-eyed with mirrored turning in VR, while gameplay is
-- fine. Hypothesis: the menu's view-target camera has bConstrainAspectRatio=true (letterboxing), which
-- UEVR's stereo projection doesn't handle. This script logs every view-target change (actor, class, FOV,
-- each camera component's constraint/aspect/FOV) and, when the setting below is on, turns the constraint off.
--
-- Setting (live, re-read every second): scripts\votv_settings.txt, line "menu_unconstrain_aspect=1" (0 = off,
-- probe only). Missing file = on. Log lines start with "[votv]" in the profile's log.txt.

-- Only UEVR-provided APIs are used (uevr.*, UEVR_UObjectHook, fs); UEVR's Lua has no os.getenv/io.
-- Everything runs inside pcall so an error is logged, never a blocking error dialog.

local api = uevr.api
local SETTINGS = "$scripts/votv_settings.txt"   -- fs path: "$scripts/" = this profile's scripts folder

local function log(s) print("[votv] " .. s) end

local function read_setting(name, default)
    local ok, val = pcall(function()
        local text = fs.read(SETTINGS)
        if type(text) ~= "string" then return nil end
        return text:match(name .. "%s*=%s*(%-?%d+)")
    end)
    if ok and val then return tonumber(val) end
    return default
end

local function name_of(o)
    if o == nil then return "nil" end
    local ok, n = pcall(function() return o:get_full_name() end)
    return ok and n or "?"
end

local function try(f, fallback)
    local ok, v = pcall(f)
    if ok then return v end
    return fallback
end

local cam_classes = nil
local function camera_classes()
    if cam_classes == nil then
        cam_classes = {}
        for _, n in ipairs({ "Class /Script/Engine.CameraComponent", "Class /Script/CinematicCamera.CineCameraComponent" }) do
            local c = try(function() return api:find_uobject(n) end, nil)
            if c ~= nil then table.insert(cam_classes, c) end
        end
    end
    return cam_classes
end

local function all_cameras()
    local seen, list = {}, {}
    for _, c in ipairs(camera_classes()) do
        local objs = try(function() return UEVR_UObjectHook.get_objects_by_class(c, false) end, {}) or {}
        for _, o in ipairs(objs) do
            local n = name_of(o)
            if not seen[n] then seen[n] = true; table.insert(list, o) end
        end
    end
    return list
end

local function describe_camera(cam)
    return string.format("%s constrain=%s aspect=%s fov=%s",
        name_of(cam),
        tostring(try(function() return cam.bConstrainAspectRatio end, "?")),
        tostring(try(function() return cam.AspectRatio end, "?")),
        tostring(try(function() return cam.FieldOfView end, "?")))
end

local last_target = nil
local fixed = {}
local acc = 0.0

local function tick()
    local pc = api:get_player_controller(0)
    if pc == nil then return end
    local target = try(function() return pc:GetViewTarget() end, nil)
    local tname = name_of(target)
    local fix_on = read_setting("menu_unconstrain_aspect", 1) == 1

    if tname ~= last_target then
        last_target = tname
        local pcm = try(function() return pc.PlayerCameraManager end, nil)
        log("view target changed: " .. tname)
        log("  camera manager " .. name_of(pcm) ..
            " fov=" .. tostring(try(function() return pcm:GetFOVAngle() end, "?")) ..
            " defaultConstrain=" .. tostring(try(function() return pcm.bDefaultConstrainAspectRatio end, "?")) ..
            " defaultAspect=" .. tostring(try(function() return pcm.DefaultAspectRatio end, "?")))
        local cams = all_cameras()
        log("  " .. #cams .. " camera component(s) in memory; menu_unconstrain_aspect=" .. (fix_on and "1" or "0"))
        for i, cam in ipairs(cams) do
            if i > 20 then log("  (more cameras not listed)"); break end
            log("  cam " .. describe_camera(cam))
        end
    end

    if fix_on then
        for _, cam in ipairs(all_cameras()) do
            if try(function() return cam.bConstrainAspectRatio end, false) == true then
                local n = name_of(cam)
                local ok = pcall(function() cam.bConstrainAspectRatio = false end)
                if not fixed[n] then
                    fixed[n] = true
                    log("unconstrained aspect ratio on " .. n .. (ok and "" or " (write FAILED)") ..
                        "; now constrain=" .. tostring(try(function() return cam.bConstrainAspectRatio end, "?")))
                end
            end
        end
    end
end

local ok_start, err_start = pcall(function()
    uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
        local ok, err = pcall(function()
            acc = acc + (delta or 0)
            if acc < 1.0 then return end
            acc = 0.0
            tick()
        end)
        if not ok then pcall(log, "tick error: " .. tostring(err)) end
    end)
end)
pcall(log, ok_start and "votv_menu_camera.lua loaded" or ("votv_menu_camera.lua failed to start: " .. tostring(err_start)))
