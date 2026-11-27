-- VOTV VR: main menu handling (UEVR Lua). Menu thread, 2026-11-27.
--
-- The main menu (world /Game/menu.menu, view target CameraActor_1, fov 110) looks cross-eyed in VR. Eye
-- captures (2026-11-27 01:13) show why: the menu widget (ui_menu_C) draws a flat picture of the scene, shown
-- on UEVR's UI panel in front of the same scene rendered in 3D. User decision (00:55): show the main menu as
-- a flat 2D screen (UEVR 2D screen mode while the menu world is active; menu_2d, default on), stereo 3D
-- everywhere else. Also logs the menu's camera, widgets and cursor state. Parked, default off: a view lock
-- (HMD removed in the post stereo-view-offset callback) and hiding ui_menu_C's BackgroundBlur children.
--   menu_2d (1)                1 = flat 2D main menu, 0 = stereo menu
--
-- Live settings: scripts\votv\settings.lua (a Lua table, re-read every second; missing = default):
--   menu_lock_view (0)         1 = lock the menu view to the face; 0 = normal head tracking
--   menu_ipd_cm (6.4)          eye separation used while locked (centimetres, real-world)
--   menu_eye_sign (1)          -1 swaps the eyes while locked
--   menu_map_pattern ("/game/menu%.menu")  Lua pattern matched (lowercased) against the world's full name
--   menu_unconstrain_aspect (0) 1 = set bConstrainAspectRatio=false on every camera (didn't help)
-- Log lines go to UEVR's log.txt via uevr.params.functions.log_info, prefixed "[votv]".
--
-- Only UEVR-provided APIs are used (uevr.*, UEVR_UObjectHook, require); UEVR 1.05's Lua has no fs/io/os.
-- Everything runs inside pcall so an error is logged, never a blocking error dialog.

local api = uevr.api

local function log(s)
    local msg = "[votv] " .. tostring(s)
    local ok = pcall(function() uevr.params.functions.log_info(msg) end)
    if not ok then pcall(print, msg) end
end

local function try(f, fallback)
    local ok, v = pcall(f)
    if ok then return v end
    return fallback
end

-- Settings: UEVR 1.05's Lua has no `fs` (log 2026-11-27 01:22: "attempt to index a nil value (global 'fs')"),
-- and no io/os. So settings live in a Lua module, scripts\votv\settings.lua (returns a table), loaded with
-- require and re-loaded every second (package.loaded cleared) so edits apply live. UEVR only auto-runs
-- top-level scripts, so the subfolder module is not executed on its own. Defaults must be safe.
-- require() search path: UEVR 1.05 leaves package.path at the game's exe folder (log 2026-11-27 01:27:
-- "module 'votv/settings' not found ... no file '...\Binaries\Win64\votv/settings.lua'"). Add this script's
-- own folder. debug.getinfo gave nothing in game (log 01:40: "script dir nil"), so UEVR's persistent-dir
-- function (API.h UEVR_PluginFunctions.get_persistent_dir = the profile folder) is tried first, in the
-- call styles a binding might use. The source of the path is logged once in load_settings.
local script_dir, script_dir_from = nil, "none"
local function try_dir(from, f)
    if script_dir ~= nil then return end
    local ok, d = pcall(f)
    if ok and type(d) == "string" and #d > 0 then
        if not d:find("[\\/]$") then d = d .. "\\" end
        script_dir, script_dir_from = d, from
    end
end
try_dir("functions.get_persistent_dir", function() return uevr.params.functions.get_persistent_dir() .. "\\scripts" end)
try_dir("functions:get_persistent_dir", function() return uevr.params.functions:get_persistent_dir() .. "\\scripts" end)
try_dir("api:get_persistent_dir", function() return uevr.api:get_persistent_dir() .. "\\scripts" end)
try_dir("debug.getinfo", function() return debug.getinfo(1, "S").source:match("^@(.*[\\/])") end)
if script_dir ~= nil then
    pcall(function() package.path = script_dir .. "?.lua;" .. package.path end)
end

-- The menu's flat copy of the scene: ui_menu_C's two direct BackgroundBlur children (probe 01:40: the only
-- direct children that sample the scene; no image there holds a scene texture). Hidden while in the menu
-- world unless settings.lua says otherwise (menu_hide_widgets = {} turns it off).
DEFAULT_HIDE = {}   -- staged: { "BackgroundBlur_76", "BackgroundBlur" } once the menu test owns the game
local settings = {}
local settings_state = nil   -- "ok" / "missing", logged on change
local function load_settings()
    local ok, t = pcall(function()
        package.loaded["votv/settings"] = nil
        return require("votv/settings")
    end)
    local state
    if ok and type(t) == "table" then settings = t; state = "ok" else settings = {}; state = "missing" end
    if state ~= settings_state then
        settings_state = state
        if state == "ok" then
            local keys = {}
            for k, v in pairs(settings) do table.insert(keys, k .. "=" .. tostring(v)) end
            table.sort(keys)
            log("settings loaded from " .. tostring(script_dir) .. "votv/settings.lua (dir via " .. script_dir_from .. "): " .. table.concat(keys, " "))
        else
            log("settings not loaded (script dir " .. tostring(script_dir) .. " via " .. script_dir_from .. "; " .. tostring(t) .. "): using defaults (menu view lock OFF, hide " .. table.concat(DEFAULT_HIDE, ",") .. ")")
        end
    end
end

local function setting_num(name, default)
    local v = tonumber(settings[name])
    if v == nil then return default end
    return v
end

local function setting_str(name, default)
    local v = settings[name]
    if type(v) ~= "string" then return default end
    return v
end

local function name_of(o)
    if o == nil then return "nil" end
    local ok, n = pcall(function() return o:get_full_name() end)
    return ok and n or "?"
end

-- UEVR mod values (same keys as config.txt). Both call styles tried; the binding style isn't documented.
local function set_mod(key, value)
    local ok = pcall(function() uevr.params.vr.set_mod_value(key, value) end)
    if not ok then ok = pcall(function() uevr.params.vr:set_mod_value(key, value) end) end
    return ok
end

local function get_mod(key)
    local v = try(function() return uevr.params.vr.get_mod_value(key) end, nil)
    if v == nil then v = try(function() return uevr.params.vr:get_mod_value(key) end, nil) end
    return v
end

-- Camera probe (diagnostics only) ------------------------------------------------------------------------
local cam_classes = nil
local function all_cameras()
    if cam_classes == nil then
        cam_classes = {}
        for _, n in ipairs({ "Class /Script/Engine.CameraComponent", "Class /Script/CinematicCamera.CineCameraComponent" }) do
            local c = try(function() return api:find_uobject(n) end, nil)
            if c ~= nil then table.insert(cam_classes, c) end
        end
    end
    local seen, list = {}, {}
    for _, c in ipairs(cam_classes) do
        local objs = try(function() return UEVR_UObjectHook.get_objects_by_class(c, false) end, {}) or {}
        for _, o in ipairs(objs) do
            local n = name_of(o)
            if not seen[n] then seen[n] = true; table.insert(list, o) end
        end
    end
    return list
end

local function log_cameras(pc)
    local pcm = try(function() return pc.PlayerCameraManager end, nil)
    log("  camera manager " .. name_of(pcm) ..
        " fov=" .. tostring(try(function() return pcm:GetFOVAngle() end, "?")) ..
        " defaultConstrain=" .. tostring(try(function() return pcm.bDefaultConstrainAspectRatio end, "?")))
    local cams = all_cameras()
    log("  " .. #cams .. " camera component(s)")
    for i, cam in ipairs(cams) do
        if i > 20 then log("  (more not listed)"); break end
        log(string.format("  cam %s constrain=%s aspect=%s fov=%s", name_of(cam),
            tostring(try(function() return cam.bConstrainAspectRatio end, "?")),
            tostring(try(function() return cam.AspectRatio end, "?")),
            tostring(try(function() return cam.FieldOfView end, "?"))))
    end
end

-- Widget probe (diagnostics only): which UMG widgets are on screen in the menu. The menu's framed
-- "picture" of the dishes is drawn inside a widget on UEVR's UI panel (eye captures 2026-11-27 01:13);
-- this finds which one, so it can be hidden later.
-- Children of a visible menu widget (ui_menu_C): class, name, visibility, and for images the brush resource.
-- Children are named "<Class> <outer path>.<ui_menu_C instance>.WidgetTree.<child>".
local function log_widget_tree(w)
    -- ui_menu_C holds ~7900 widgets (nested settings slots etc., log 2026-11-27 01:27), so instead of listing
    -- them: count per class, then list every widget whose brush/background has a resource (texture, material,
    -- render target) or whose class can show the scene (BackgroundBlur, RetainerBox, Viewport, NativeWidgetHost).
    local wname = name_of(w)
    local inst = wname:match("%.([^%.]+)$")
    if inst == nil then return end
    local cls = try(function() return api:find_uobject("Class /Script/UMG.Widget") end, nil)
    if cls == nil then log("  tree: Widget class not found"); return end
    local objs = try(function() return UEVR_UObjectHook.get_objects_by_class(cls, false) end, {}) or {}
    local key = "." .. inst .. ".WidgetTree."
    local counts, seen_res, listed, n = {}, {}, 0, 0
    local scene_classes = { BackgroundBlur = true, RetainerBox = true, Viewport = true, NativeWidgetHost = true }
    for _, c in ipairs(objs) do
        local cn = name_of(c)
        if cn:find(key, 1, true) then
            n = n + 1
            local klass = cn:match("^(%S+)") or "?"
            counts[klass] = (counts[klass] or 0) + 1
            local r = try(function() return c.Brush.ResourceObject end, nil)
            if r == nil then r = try(function() return c.Background.ResourceObject end, nil) end
            local rname = r ~= nil and name_of(r) or nil
            local interesting = scene_classes[klass] or (rname ~= nil and not rname:find("_16x", 1, true))
            if interesting then
                local sig = klass .. "|" .. tostring(rname)
                seen_res[sig] = (seen_res[sig] or 0) + 1
                if seen_res[sig] <= 3 and listed < 80 then
                    listed = listed + 1
                    local path = cn:gsub("^%S+ ", ""):gsub("^.-" .. inst:gsub("%p", "%%%0") .. "%.WidgetTree%.", "")
                    log(string.format("    %s %s vis=%s res=%s", klass, path,
                        tostring(try(function() return c:GetVisibility() end, "?")), tostring(rname)))
                end
            end
        end
    end
    local parts = {}
    for k, v in pairs(counts) do table.insert(parts, k .. "=" .. v) end
    table.sort(parts)
    log("  " .. inst .. ": " .. n .. " widget(s) by class: " .. table.concat(parts, " "))
    local rp = {}
    for k, v in pairs(seen_res) do table.insert(rp, k .. " x" .. v) end
    table.sort(rp)
    log("  resources: " .. table.concat(rp, " ; "))
end

-- UFunction probe (diagnostics only): Blueprint functions of the menu-type widget classes, to find what a
-- button click calls (e.g. "BndEvt__button_start_..._OnClicked", "proceed"). Injected OS mouse clicks did
-- not press "Proceed" on the OMEGA WARNING screen (controls thread, 2026-11-27), so the laser pointer may
-- need to call these directly. Logged once per class per session.
local funcs_logged = {}
local function log_class_functions(class_short)
    if funcs_logged[class_short] then return end
    funcs_logged[class_short] = true
    local fcls = try(function() return api:find_uobject("Class /Script/CoreUObject.Function") end, nil)
    if fcls == nil then log("  functions: Function class not found"); return end
    local objs = try(function() return UEVR_UObjectHook.get_objects_by_class(fcls, false) end, {}) or {}
    local key = "." .. class_short .. ":"
    local names = {}
    for _, f in ipairs(objs) do
        local n = name_of(f)
        local s, e = n:find(key, 1, true)
        if s ~= nil then table.insert(names, n:sub(e + 1)) end
    end
    table.sort(names)
    log("  functions of " .. class_short .. " (" .. #names .. "): " .. table.concat(names, ", "))
end

local function log_widgets()
    local cls = try(function() return api:find_uobject("Class /Script/UMG.UserWidget") end, nil)
    if cls == nil then log("  widgets: UserWidget class not found"); return end
    local objs = try(function() return UEVR_UObjectHook.get_objects_by_class(cls, false) end, {}) or {}
    local n = 0
    for _, w in ipairs(objs) do
        local inv = try(function() return w:IsInViewport() end, nil)
        if inv == true then
            n = n + 1
            if n <= 30 then
                log(string.format("  widget %s visible=%s", name_of(w), tostring(try(function() return w:IsVisible() end, "?"))))
            end
            if try(function() return w:IsVisible() end, false) == true then
                local cshort = name_of(w):match("^(%S+)")
                if cshort then log_class_functions(cshort) end
            end
            if name_of(w):find("ui_menu_C", 1, true) and try(function() return w:IsVisible() end, false) == true then
                log_widget_tree(w)
            end
        end
    end
    log("  " .. n .. " user widget(s) in viewport (of " .. #objs .. " in memory)")
end

-- Hide chosen children of the visible ui_menu_C while in the menu (setting menu_hide_widgets, a list of
-- widget names as logged by the tree probe, e.g. "Image_12"; default empty = nothing hidden). Each hidden
-- widget's previous visibility is remembered and put back on leaving the menu. ESlateVisibility: 0 Visible,
-- 1 Collapsed, 2 Hidden, 3 HitTestInvisible, 4 SelfHitTestInvisible.
local hidden = {}   -- full name -> { widget, previous visibility }
local hide_tries = 0

local function find_menu_children(names)
    local found = {}
    if type(names) ~= "table" or #names == 0 then return found end
    local ucls = try(function() return api:find_uobject("Class /Script/UMG.UserWidget") end, nil)
    local wcls = try(function() return api:find_uobject("Class /Script/UMG.Widget") end, nil)
    if ucls == nil or wcls == nil then return found end
    local menu_inst = nil
    for _, u in ipairs(try(function() return UEVR_UObjectHook.get_objects_by_class(ucls, false) end, {}) or {}) do
        local n = name_of(u)
        if n:find("ui_menu_C", 1, true) and try(function() return u:IsInViewport() end, false) == true then
            menu_inst = n:match("%.([^%.]+)$")
            break
        end
    end
    if menu_inst == nil then return found end
    local want = {}
    for _, nm in ipairs(names) do want[nm] = true end
    -- direct children of the menu's own WidgetTree only (not nested user widgets)
    local key = "." .. menu_inst .. ".WidgetTree."
    for _, c in ipairs(try(function() return UEVR_UObjectHook.get_objects_by_class(wcls, false) end, {}) or {}) do
        local cn = name_of(c)
        local s, e = cn:find(key, 1, true)
        if s ~= nil then
            local rest = cn:sub(e + 1)
            if not rest:find("%.") and want[rest] then table.insert(found, c) end
        end
    end
    return found
end

local function hide_menu_widgets()
    local names = settings.menu_hide_widgets or DEFAULT_HIDE
    for _, c in ipairs(find_menu_children(names)) do
        local cn = name_of(c)
        if hidden[cn] == nil then
            local prev = try(function() return c:GetVisibility() end, 0)
            local ok = pcall(function() c:SetVisibility(2) end)
            hidden[cn] = { c, prev }
            log("menu: hid " .. cn .. " (was " .. tostring(prev) .. (ok and "" or ", SetVisibility FAILED") .. ")")
        end
    end
end

local function restore_menu_widgets()
    for cn, h in pairs(hidden) do
        pcall(function() h[1]:SetVisibility(h[2]) end)
        log("menu: restored " .. cn)
    end
    hidden = {}
end

-- Menu state ---------------------------------------------------------------------------------------------
local last_world, last_target = nil, nil
local in_menu = false
local lock_on, ipd_cm, eye_sign = true, 6.4, 1
local twod_applied = nil -- last VR_2DScreenMode value this script set (nil = not yet)
local base = {}          -- per view index: {px,py,pz, rx,ry,rz} from the early callback (camera before HMD)
local sampled = {}       -- per view index: logged one sample of early vs post for diagnosis

local function world_name()
    local engine = try(function() return api:get_engine() end, nil)
    local world = try(function() return engine.GameViewport.World end, nil)
    return name_of(world)
end

local function tick()
    load_settings()
    lock_on = setting_num("menu_lock_view", 0) == 1   -- default OFF
    ipd_cm = setting_num("menu_ipd_cm", 6.4)
    eye_sign = setting_num("menu_eye_sign", 1) >= 0 and 1 or -1

    local pc = api:get_player_controller(0)
    local wname = world_name()
    local target = pc and try(function() return pc:GetViewTarget() end, nil) or nil
    local tname = name_of(target)
    if wname ~= last_world or tname ~= last_target then
        last_world, last_target = wname, tname
        log("world " .. wname .. " | view target " .. tname)
        if pc then
            log_cameras(pc)
            -- Cursor diagnosis: is the game asking for a (hardware) mouse cursor here?
            log("  cursor: bShowMouseCursor=" .. tostring(try(function() return pc.bShowMouseCursor end, "?")) ..
                " DefaultMouseCursor=" .. tostring(try(function() return pc.DefaultMouseCursor end, "?")) ..
                " CurrentMouseCursor=" .. tostring(try(function() return pc.CurrentMouseCursor end, "?")))
        end
        log_widgets()
    end

    -- Flat-menu worlds: the main menu and the start-up level with the OMEGA WARNING screen (preLoad; the
    -- pointer is only active in 2D mode, so the warning screen needs it too: live session 2026-11-27 02:36).
    -- menu_map_pattern (one Lua pattern) replaces the list if set.
    local wl = wname:lower()
    local menu_now = false
    local custom = setting_str("menu_map_pattern", nil)
    for _, pat in ipairs(custom and { custom:lower() } or { "/game/menu%.menu", "/game/maps/preload%.preload" }) do
        if wl:find(pat) ~= nil then menu_now = true end
    end
    if menu_now ~= in_menu then
        in_menu = menu_now
        sampled = {}
        log(menu_now and ("menu: view lock " .. (lock_on and "ON" or "off") .. string.format(" (ipd %.1f cm, eye sign %d)", ipd_cm, eye_sign))
                     or "left menu: normal head tracking")
        if not menu_now then restore_menu_widgets() end
        hide_tries = 0
    end

    -- Flat 2D main menu (user decision 2026-11-27 00:55): UEVR's 2D screen mode while the menu world is
    -- active, stereo everywhere else (the pause menu lives in the gameplay world, so it stays 3D). Applied
    -- only when the wanted value changes, also on the first tick (an earlier run may have left UEVR's saved
    -- config in 2D), so a manual UEVR 2D toggle in gameplay isn't fought every second. menu_2d=0 disables it.
    local want2d = menu_now and setting_num("menu_2d", 1) == 1
    if want2d ~= twod_applied then
        local ok = set_mod("VR_2DScreenMode", want2d and "true" or "false")
        log((want2d and "menu: flat 2D screen on" or "stereo 3D (2D screen off)") .. " (" .. (ok and "ok" or "set_mod_value FAILED") .. ")")
        twod_applied = want2d
    end

    -- Hide the configured menu children until every name is found; give up after 10 scans (logged), since
    -- each scan walks every UMG widget in memory.
    if in_menu then
        local names = settings.menu_hide_widgets or DEFAULT_HIDE
        local want = (type(names) == "table") and #names or 0
        local have = 0
        for _ in pairs(hidden) do have = have + 1 end
        if want > 0 and have < want and hide_tries < 10 then
            hide_tries = hide_tries + 1
            hide_menu_widgets()
            if hide_tries == 10 then
                local now = 0
                for _ in pairs(hidden) do now = now + 1 end
                if now < want then log("menu: only " .. now .. " of " .. want .. " menu_hide_widgets found after 10 scans; stopped looking") end
            end
        end
    end

    if setting_num("menu_unconstrain_aspect", 0) == 1 then
        for _, cam in ipairs(all_cameras()) do
            if try(function() return cam.bConstrainAspectRatio end, false) == true then
                pcall(function() cam.bConstrainAspectRatio = false end)
            end
        end
    end
end

-- UE right axis (Y) of a rotator in degrees.
local function right_axis(pitch, yaw, roll)
    local p, y, r = math.rad(pitch), math.rad(yaw), math.rad(roll)
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    return sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp
end

local function on_early(device, view_index, world_to_meters, position, rotation, is_double)
    if not in_menu then return end
    base[view_index] = { position.x, position.y, position.z, rotation.x, rotation.y, rotation.z }
end

local function on_post(device, view_index, world_to_meters, position, rotation, is_double)
    if not in_menu then return end
    local b = base[view_index]
    if b == nil then return end
    if not sampled[view_index] then
        sampled[view_index] = true
        log(string.format("menu view %d: camera pos (%.1f %.1f %.1f) rot (%.1f %.1f %.1f) -> with HMD pos (%.1f %.1f %.1f) rot (%.1f %.1f %.1f), w2m %.1f",
            view_index, b[1], b[2], b[3], b[4], b[5], b[6], position.x, position.y, position.z, rotation.x, rotation.y, rotation.z, world_to_meters or -1))
    end
    if not lock_on then return end
    local rx, ry, rz = right_axis(b[4], b[5], b[6])
    -- UEVR passes view indices 1 (left) and 2 (right) here (log 2026-11-27 01:10), not 0/1.
    local side = (view_index % 2 == 1) and -1 or 1
    local half = (ipd_cm / 100.0) * (world_to_meters or 100.0) * 0.5 * side * eye_sign
    position.x = b[1] + rx * half
    position.y = b[2] + ry * half
    position.z = b[3] + rz * half
    rotation.x, rotation.y, rotation.z = b[4], b[5], b[6]
end

local acc = 0.0
local errors_logged = 0
local function log_error(where, err)
    errors_logged = errors_logged + 1
    if errors_logged <= 10 then pcall(log, where .. " error: " .. tostring(err)) end   -- first 10 only
end
local ok_start, err_start = pcall(function()
    uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function(...)
        local ok, err = pcall(on_early, ...)
        if not ok then log_error("early view", err) end
    end)
    uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(...)
        local ok, err = pcall(on_post, ...)
        if not ok then log_error("post view", err) end
    end)
    uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
        local ok, err = pcall(function()
            acc = acc + (delta or 0)
            if acc < 1.0 then return end
            acc = 0.0
            tick()
        end)
        if not ok then log_error("tick", err) end
    end)
end)
pcall(log, ok_start and "votv_menu_camera.lua loaded" or ("votv_menu_camera.lua failed to start: " .. tostring(err_start)))
