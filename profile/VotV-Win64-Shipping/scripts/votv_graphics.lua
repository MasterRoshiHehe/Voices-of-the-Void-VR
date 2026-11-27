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
-- Live A/B: removing a cvar from gfx_set, or setting gfx_override_enable = 0, restores the value the game had
-- before our first write ("override reverted name -> original").
-- Log lines go to UEVR's log.txt via uevr.params.functions.log_info, prefixed "[votv-gfx]". Frame-stats and
-- cvar lines carry "map=<world> loc=<x,y,z>" (player pawn location in metres) so scenes in one map can be told apart.
--
-- Frame times come from on_pre_engine_tick's delta (engine delta seconds: affected by the game's max-delta
-- clamp and time dilation, not a GPU or compositor measurement). Use it to compare scenes and A/B runs, and
-- confirm headline numbers with an external capture.
--
-- Only UEVR-provided APIs are used (uevr.*, require); UEVR 1.05's Lua has no fs/io/os and print() does not
-- reach log.txt (both found by the menu thread, STATUS.md 2026-11-27). Everything runs in pcall.

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

-- require() search path. UEVR 1.05 leaves package.path at the game's exe folder plus ".\?.lua", and the
-- working directory is the profile's scripts folder only while scripts load (run 2026-11-27_01-45-25: the
-- load-time require worked, the next one 3 s later did not). debug.getinfo and get_persistent_dir gave no
-- folder (menu thread, same runs). So the folder comes from the first candidate that answers:
--   debug.getinfo source ("@path" or "=path"), UEVR persistent dir (+ \scripts), and finally an optional
--   scripts\votv\paths.lua returning { scripts_dir = [[...]] } (NOT generated yet: a launcher would write it
--   into the profile each run; it must never be committed, since it holds a local path), required once at
--   load while ".\" still resolves to the scripts folder.
-- The resolved folder and its source are logged once. With none, the load-time settings (read while ".\"
-- still works) stay in use as the last good settings, so live edits are not picked up in that case.
local script_dir, script_dir_from = nil, "none"
local function try_dir(from, f)
    if script_dir ~= nil then return end
    local ok, d = pcall(f)
    if ok and type(d) == "string" and #d > 0 then
        if not d:find("[\\/]$") then d = d .. "\\" end
        script_dir, script_dir_from = d, from
    end
end
try_dir("debug.getinfo", function()
    local info = debug.getinfo(1, "S")
    return (info.source:match("^[@=](.*[\\/])")) or (info.short_src:match("^(.*[\\/])"))
end)
try_dir("functions.get_persistent_dir", function() return uevr.params.functions.get_persistent_dir() .. "\\scripts" end)
try_dir("api:get_persistent_dir", function() return uevr.api:get_persistent_dir() .. "\\scripts" end)
try_dir("votv/paths.lua", function()
    package.loaded["votv/paths"] = nil
    local t = require("votv/paths")
    return type(t) == "table" and t.scripts_dir or nil
end)
if script_dir ~= nil and not package.path:find(script_dir, 1, true) then
    pcall(function() package.path = script_dir .. "?.lua;" .. package.path end)
end
log("scripts folder for require: " .. tostring(script_dir) .. " (via " .. script_dir_from .. ")")

local DEFAULTS = { gfx_log_interval_s = 10, gfx_reapply_interval_s = 2, gfx_override_enable = 0 }

-- Logs "settings: ok ... / missing (...)" at startup and whenever that result changes, so a silent fallback
-- can't hide.
local last_read_status = nil
local function note_read_status(status)
    if status ~= last_read_status then
        last_read_status = status
        log("settings (scripts/votv/settings.lua): " .. status)
    end
end

local last_good = nil   -- last successfully parsed settings; kept when a later read fails

local function read_settings()
    local s = { overrides = {} }
    for k, v in pairs(DEFAULTS) do s[k] = v end
    local ok, t = pcall(function()
        package.loaded["votv/settings"] = nil
        return require("votv/settings")
    end)
    if not ok or type(t) ~= "table" then
        local err = (tostring(t):gsub("\n.*", ""))
        if last_good ~= nil then
            note_read_status("read failed (" .. err .. "): keeping the last good settings")
            return last_good
        end
        note_read_status("missing (" .. err .. "): defaults, overrides off")
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
    last_good = s
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

local cvar_cache = {}

local function find_cvar(name)
    local c = cvar_cache[name]
    if c ~= nil then return c end
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

local function number_text(x)
    if x == nil then return "nil" end
    if math.abs(x - math.floor(x)) < 1e-6 then return string.format("%d", math.floor(x)) end
    return string.format("%.6g", x)
end

-- Writes a value: set_int / set_float first, the console command if the read-back differs.
local function write_cvar(name, value, text)
    local v = find_cvar(name)
    if v == nil then return "missing", nil end
    local method = "set"
    local ok = pcall(function()
        if text:find("[%.eE]") then v:set_float(value) else v:set_int(math.floor(value)) end
    end)
    local after = cvar_number(name)
    if not ok or after == nil or math.abs(after - value) >= 1e-4 then
        method = "execute_command"
        pcall(function() api:execute_command(name .. " " .. text) end)
        after = cvar_number(name)
    end
    return method, after
end

-- ---------------------------------------------------------------- scene tagging

local function map_name()
    return try(function()
        local world = api:get_engine().GameViewport.World
        local n = name_of(world)
        return (n:match("([^%s%.:]+)$")) or n
    end, "?")
end

-- Player pawn location in metres (UE units are cm), rounded to 1 m: "x,y,z", "nopawn" or "?".
local function pawn_loc()
    return try(function()
        local pc = api:get_player_controller(0)
        local pawn = try(function() return pc:K2_GetPawn() end, nil) or try(function() return pc.Pawn end, nil)
        if pawn == nil then return "nopawn" end
        local p = pawn:K2_GetActorLocation()
        local function m(v) return string.format("%d", math.floor(v / 100 + 0.5)) end
        return m(p.X) .. "," .. m(p.Y) .. "," .. m(p.Z)
    end, "?")
end

local function scene_tag()
    return "map=" .. map_name() .. " loc=" .. pawn_loc()
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
    log("cvars (" .. reason .. ", " .. scene_tag() .. "): " .. table.concat(parts, " "))
end

local function check_cvar_changes()
    for _, n in ipairs(WATCHED) do
        local t = cvar_text(n)
        if last_values[n] ~= nil and t ~= last_values[n] then
            log("cvar changed: " .. n .. " " .. last_values[n] .. " -> " .. t .. " (" .. scene_tag() .. ")")
        end
        last_values[n] = t
    end
end

-- ---------------------------------------------------------------- frame timer

-- Missed frames: longer than 1.5x a refresh budget. "miss" uses the window's median delta as the budget (the
-- headset paces the game, so the median is the refresh interval; hz~ shows it); miss72 / miss90 use fixed
-- 72 / 90 Hz budgets.
local frames = {}

local function frame_summary()
    local n = #frames
    if n == 0 then return end
    local sorted, sum = {}, 0
    for i, ms in ipairs(frames) do sorted[i] = ms; sum = sum + ms end
    table.sort(sorted)
    local function pct(p) return sorted[math.max(1, math.min(n, math.ceil(p * n)))] end
    local median = pct(0.50)
    local lim_med, lim72, lim90 = 1.5 * median, 1.5 * 1000 / 72, 1.5 * 1000 / 90
    local miss, miss72, miss90 = 0, 0, 0
    for _, ms in ipairs(frames) do
        if ms > lim_med then miss = miss + 1 end
        if ms > lim72 then miss72 = miss72 + 1 end
        if ms > lim90 then miss90 = miss90 + 1 end
    end
    log(string.format("frames %s n=%d mean=%.2fms p50=%.2f p95=%.2f p99=%.2f max=%.2f hz~%.1f miss=%d miss72=%d miss90=%d",
        scene_tag(), n, sum / n, median, pct(0.95), pct(0.99), sorted[n], 1000 / median, miss, miss72, miss90))
    frames = {}
end

-- ---------------------------------------------------------------- overrides

-- originals[name] = { value, text }: the game's value before our first write; restored when the cvar leaves
-- gfx_set or gfx_override_enable goes to 0.
local originals = {}
local missing_logged = {}

local function apply_override(o)
    if find_cvar(o.name) == nil then
        if not missing_logged[o.name] then
            missing_logged[o.name] = true
            log("override skipped, cvar missing: " .. o.name)
        end
        return
    end
    local cur = cvar_number(o.name)
    if cur ~= nil and math.abs(cur - o.value) < 1e-4 then return end
    local first = originals[o.name] == nil
    if first then originals[o.name] = { value = cur, text = number_text(cur) } end
    local method, after = write_cvar(o.name, o.value, o.text)
    log(string.format("%s %s: %s -> %s via %s, now %s (%s)",
        first and "override applied" or "override RE-applied (value drifted)",
        o.name, number_text(cur), o.text, method, number_text(after), scene_tag()))
end

local function revert_unlisted(active)
    for name, orig in pairs(originals) do
        if not active[name] then
            originals[name] = nil
            if orig.value == nil then
                log("override reverted " .. name .. ": original unknown, left at " .. number_text(cvar_number(name)))
            else
                local method, after = write_cvar(name, orig.value, orig.text)
                log(string.format("override reverted %s -> %s via %s, now %s (%s)",
                    name, orig.text, method, number_text(after), scene_tag()))
            end
        end
    end
end

-- ---------------------------------------------------------------- tick

local settings = read_settings()
local acc_settings, acc_log, acc_reapply = 0.0, 0.0, 0.0
local started = false
local last_override_state = nil

local function active_set()
    local a = {}
    if settings.gfx_override_enable == 1 then
        for _, o in ipairs(settings.overrides) do a[o.name] = true end
    end
    return a
end

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
        local state = settings.gfx_override_enable == 1 and ("on, " .. #settings.overrides .. " gfx_set entries") or "off"
        if state ~= last_override_state then
            last_override_state = state
            log("overrides " .. state)
        end
        local ok, err = pcall(revert_unlisted, active_set())
        if not ok then log("revert error: " .. tostring(err)) end
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
