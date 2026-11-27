-- VOTV VR: graphics probe (cvar logger, frame timer) and opt-in cvar overrides (UEVR Lua, 2026-11-27).
--
-- Why: VR comfort tuning (motion blur, DOF, fringe, grain, AA, sharpening, ...) needs to know what the game
-- itself sets, whether its settings code re-applies values, and what each change costs per frame, per scene.
-- By default this script only READS: it changes nothing about rendering unless gfx_override_enable=1.
--
-- Live settings: scripts\votv\settings.lua (shared Lua module returning a table; re-read every second;
-- missing file or key = the default):
--   gfx_log_interval_s = 10        periodic cvar dump + frame-time summary (seconds, min 1)
--   gfx_reapply_interval_s = 2     how often overrides are checked and re-applied if the value differs (min 0.5)
--   gfx_override_enable = 0        master switch for gfx_set (0 = probe only)
--   gfx_set = { ["r.MotionBlurQuality"] = 0 }   cvar -> number; only applied while gfx_override_enable = 1
-- Log lines go to UEVR's log.txt via uevr.params.functions.log_info, prefixed "[votv-gfx]".
--
-- Frame times come from on_pre_engine_tick's delta (engine delta seconds: affected by the game's max-delta
-- clamp and time dilation, not a GPU or compositor measurement). Use it to compare scenes and A/B runs, and
-- confirm headline numbers with an external capture.
--
-- Only UEVR-provided APIs are used (uevr.*, require, debug.getinfo); UEVR 1.05's Lua has no fs/io/os and
-- print() does not reach log.txt (both found by the menu thread, STATUS.md 2026-11-27). Everything runs in pcall.

local api = uevr.api
local TAG = "[votv-gfx] "

local function log(s)
    local msg = TAG .. tostring(s)
    local ok = pcall(function() uevr.params.functions.log_info(msg) end)
    if not ok then pcall(print, msg) end
end

local function try(f, fallback)
    local ok, v = pcall(f)
    if ok then return v end
    return fallback
end

local function name_of(o)
    if o == nil then return "nil" end
    local ok, n = pcall(function() return o:get_full_name() end)
    return ok and n or "?"
end

-- ---------------------------------------------------------------- settings

-- require() search path: UEVR 1.05 leaves package.path at the game's exe folder, so add this script's folder.
local script_dir = nil
pcall(function() script_dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])") end)
if script_dir ~= nil and not package.path:find(script_dir, 1, true) then
    pcall(function() package.path = script_dir .. "?.lua;" .. package.path end)
end

local DEFAULTS = { gfx_log_interval_s = 10, gfx_reapply_interval_s = 2, gfx_override_enable = 0 }

-- Logs "settings: ok ... / missing (...)" at startup and whenever that result changes, so a silent fallback
-- to the defaults can't hide.
local last_read_status = nil
local function note_read_status(status)
    if status ~= last_read_status then
        last_read_status = status
        log("settings (scripts/votv/settings.lua): " .. status)
    end
end

local function read_settings()
    local s = { overrides = {} }
    for k, v in pairs(DEFAULTS) do s[k] = v end
    local ok, t = pcall(function()
        package.loaded["votv/settings"] = nil
        return require("votv/settings")
    end)
    if not ok or type(t) ~= "table" then
        note_read_status("missing (script dir " .. tostring(script_dir) .. "; " .. tostring(t) .. "): defaults, overrides off")
        return s
    end
    for k, _ in pairs(DEFAULTS) do
        local v = tonumber(t[k])
        if v ~= nil then s[k] = v end
    end
    local names = {}
    if type(t.gfx_set) == "table" then
        for cname, cval in pairs(t.gfx_set) do
            local v = tonumber(cval)
            if type(cname) == "string" and v ~= nil then
                local text = (math.type and math.type(v) == "integer") and string.format("%d", v) or tostring(v)
                table.insert(s.overrides, { name = cname, value = v, text = text })
                table.insert(names, cname .. "=" .. text)
            end
        end
        table.sort(s.overrides, function(a, b) return a.name < b.name end)
        table.sort(names)
    end
    note_read_status(string.format("ok: log=%gs reapply=%gs override_enable=%d gfx_set={%s}",
        s.gfx_log_interval_s, s.gfx_reapply_interval_s, s.gfx_override_enable, table.concat(names, " ")))
    if s.gfx_log_interval_s < 1 then s.gfx_log_interval_s = 1 end
    if s.gfx_reapply_interval_s < 0.5 then s.gfx_reapply_interval_s = 0.5 end
    return s
end

-- ---------------------------------------------------------------- cvars

local WATCHED = {
    "r.DefaultFeature.AntiAliasing", "r.PostProcessAAQuality", "r.TemporalAASamples",
    "r.TemporalAACurrentFrameWeight", "r.TemporalAAFilterSize", "r.Tonemapper.Sharpen",
    "r.MotionBlurQuality", "r.MotionBlur.Max", "r.MotionBlur.Amount", "r.DepthOfFieldQuality",
    "r.SceneColorFringeQuality", "r.SceneColorFringe.Max", "r.LensFlareQuality", "r.BloomQuality",
    "r.Tonemapper.Quality", "r.Tonemapper.GrainQuantization", "r.EyeAdaptationQuality",
    "r.ScreenPercentage", "r.SSR.Quality", "r.VolumetricFog", "r.MSAACount", "r.ForwardShading",
    "sg.AntiAliasingQuality", "sg.PostProcessQuality",
}

local cvar_cache = {}   -- name -> variable object, or false when not found

local function find_cvar(name)
    local c = cvar_cache[name]
    if c ~= nil then return c or nil end
    local v = try(function()
        local cm = api:get_console_manager()
        if cm == nil then return nil end
        return cm:find_variable(name)
    end, nil)
    if v ~= nil then cvar_cache[name] = v end   -- not-found is retried (cvars can register late)
    return v
end

-- Value as text: "int/float" (an int cvar reads 0.0 as float and a float cvar truncates as int, so log both).
local function cvar_text(name)
    local v = find_cvar(name)
    if v == nil then return "missing" end
    local i = try(function() return v:get_int() end, nil)
    local f = try(function() return v:get_float() end, nil)
    if i == nil and f == nil then return "unreadable" end
    return string.format("%s/%s", tostring(i), f and string.format("%.4g", f) or "?")
end

local function cvar_number(name)
    local v = find_cvar(name)
    if v == nil then return nil end
    local f = try(function() return v:get_float() end, nil)
    local i = try(function() return v:get_int() end, nil)
    if f ~= nil and f ~= 0 then return f end
    if i ~= nil then return i end
    return f
end

-- ---------------------------------------------------------------- scene name

local function map_name()
    return try(function()
        local engine = api:get_engine()
        local world = engine.GameViewport.World
        local n = name_of(world)
        return (n:match("([^%s%.:]+)$")) or n
    end, "?")
end

-- ---------------------------------------------------------------- cvar logger

local last_values = {}

local function dump_cvars(reason)
    local parts = {}
    for _, n in ipairs(WATCHED) do
        local t = cvar_text(n)
        last_values[n] = t
        table.insert(parts, n .. "=" .. t)
    end
    log("cvars (" .. reason .. ", map " .. map_name() .. "): " .. table.concat(parts, " "))
end

local function check_cvar_changes()
    for _, n in ipairs(WATCHED) do
        local t = cvar_text(n)
        if last_values[n] ~= nil and t ~= last_values[n] then
            log("cvar changed: " .. n .. " " .. last_values[n] .. " -> " .. t .. " (map " .. map_name() .. ")")
        end
        last_values[n] = t
    end
end

-- ---------------------------------------------------------------- frame timer

local frames = {}

local function frame_summary()
    local n = #frames
    if n == 0 then return end
    local sorted, sum, over72, over90 = {}, 0, 0, 0
    local b72, b90 = 1000 / 72, 1000 / 90
    for i, ms in ipairs(frames) do
        sorted[i] = ms; sum = sum + ms
        if ms > b72 then over72 = over72 + 1 end
        if ms > b90 then over90 = over90 + 1 end
    end
    table.sort(sorted)
    local function pct(p) return sorted[math.max(1, math.min(n, math.ceil(p * n)))] end
    log(string.format("frames map=%s n=%d mean=%.2fms p50=%.2f p95=%.2f p99=%.2f max=%.2f over72=%d over90=%d",
        map_name(), n, sum / n, pct(0.50), pct(0.95), pct(0.99), sorted[n], over72, over90))
    frames = {}
end

-- ---------------------------------------------------------------- overrides

local applied_once = {}

local function apply_override(o)
    local cur = cvar_number(o.name)
    local v = find_cvar(o.name)
    if v == nil then
        if not applied_once[o.name .. "?missing"] then
            applied_once[o.name .. "?missing"] = true
            log("override skipped, cvar missing: " .. o.name)
        end
        return
    end
    if cur ~= nil and math.abs(cur - o.value) < 1e-4 then return end

    local method = "set"
    local ok = pcall(function()
        if o.text:find("%.") then v:set_float(o.value) else v:set_int(math.floor(o.value)) end
    end)
    local after = cvar_number(o.name)
    if not ok or after == nil or math.abs(after - o.value) >= 1e-4 then
        method = "execute_command"
        pcall(function() api:execute_command(o.name .. " " .. o.text) end)
        after = cvar_number(o.name)
    end
    local first = not applied_once[o.name]
    applied_once[o.name] = true
    log(string.format("%s %s: %s -> %s via %s, now %s (map %s)",
        first and "override applied" or "override RE-applied (value drifted)",
        o.name, tostring(cur), o.text, method, tostring(after), map_name()))
end

-- ---------------------------------------------------------------- tick

local settings = read_settings()
local acc_settings, acc_log, acc_reapply = 0.0, 0.0, 0.0
local started = false
local last_override_state = nil

local function on_tick(delta)
    delta = delta or 0
    if delta > 0 then table.insert(frames, delta * 1000) end
    acc_settings = acc_settings + delta
    acc_log = acc_log + delta
    acc_reapply = acc_reapply + delta

    if not started then
        started = true
        dump_cvars("startup")
    end

    if acc_settings >= 1.0 then
        acc_settings = 0.0
        settings = read_settings()
        local state = settings.gfx_override_enable == 1 and ("on, " .. #settings.overrides .. " gfx_set line(s)") or "off"
        if state ~= last_override_state then
            last_override_state = state
            log("overrides " .. state)
        end
        check_cvar_changes()
    end

    if settings.gfx_override_enable == 1 and acc_reapply >= settings.gfx_reapply_interval_s then
        acc_reapply = 0.0
        for _, o in ipairs(settings.overrides) do
            local ok, err = pcall(apply_override, o)
            if not ok then log("override error on " .. o.name .. ": " .. tostring(err)) end
        end
    end

    if acc_log >= settings.gfx_log_interval_s then
        acc_log = 0.0
        frame_summary()
        dump_cvars("periodic")
    end
end

local ok_start, err_start = pcall(function()
    uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
        local ok, err = pcall(on_tick, delta)
        if not ok then pcall(log, "tick error: " .. tostring(err)) end
    end)
end)
pcall(log, ok_start and "votv_graphics.lua loaded (probe only unless gfx_override_enable=1)"
    or ("votv_graphics.lua failed to start: " .. tostring(err_start)))
